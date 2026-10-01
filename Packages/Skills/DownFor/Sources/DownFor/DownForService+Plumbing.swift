import Foundation
import StarlingCore
import StarlingNegotiation

// Queues, sends, deadlines, and endings. Phase 1's DownNegotiator proved
// these patterns (ADR 0120, items 19 to 22); they are kept, keyed by run.

extension DownForService {
    // MARK: - Work queues

    /// Bounds the per-friend queues, since `handle` runs before any check of
    /// who the sender is.
    static let maxWorkers = 256
    /// While a friend's worker waits on consent or the model, at most this
    /// many of that friend's messages wait behind it. A dropped message is
    /// one more lost frame, which the friend's retries recover.
    static let maxQueuedWorkPerPeer = 64

    func enqueue(_ work: Work, for peer: PeerID) {
        if workers[peer] == nil {
            guard workers.count < Self.maxWorkers else { return }
            let (stream, queue) = AsyncStream.makeStream(of: Work.self, bufferingPolicy: .bufferingOldest(Self.maxQueuedWorkPerPeer))
            let task = Task { [weak self] in
                for await work in stream {
                    guard let self else { return }
                    await self.dequeued(peer)
                    await self.perform(work, peer: peer)
                }
            }
            workers[peer] = (queue, task)
        }
        switch workers[peer]?.queue.yield(work) {
        case .enqueued?: queued[peer, default: 0] += 1
        case .dropped?: diagnostics.droppedWork += 1
        default: break
        }
    }

    private func dequeued(_ peer: PeerID) {
        queued[peer, default: 1] -= 1
    }

    private func perform(_ work: Work, peer: PeerID) async {
        switch work {
        case .start(let id): await initiate(id, with: peer)
        case .message(let envelope): await receive(envelope)
        case .resend(let key, let token): await resend(key, token: token)
        case .act(let key, let action): await act(action, in: key)
        case .notify(let notice, let reason): await tell(notice, reason)
        }
    }

    // MARK: - Sending

    enum SendResult { case sent, lost, ended }

    /// Sends `bodies` in order, then arms the step's deadline. With
    /// `awaitingReply`, each tick resends them; otherwise the deadline only
    /// bounds the wait for the peer's next move. With `keepDeadline`, the
    /// current deadline keeps running.
    func transmit(
        _ bodies: [MessageBody], in key: RunKey, awaitingReply: Bool,
        attemptLimit: Int? = nil, backsOff: Bool = false, keepDeadline: Bool = false
    ) async {
        guard runs[key] != nil else { return }
        // The deadline starts before the first send, so it also bounds a
        // send that waits on the owner's consent.
        if !keepDeadline { beginStep(key, attemptLimit: attemptLimit ?? configuration.maxAttempts, backsOff: backsOff) }
        for body in bodies {
            guard await send(body, in: key) != .ended, runs[key] != nil else { return }
        }
        runs[key]?.outstanding = awaitingReply ? bodies : []
    }

    /// The last check before the Outbox for a live run. A gate refusal, a
    /// policy denial, or declined consent ends the run. A transport error is
    /// `.lost`: the deadline's resends cover lost frames.
    func send(_ body: MessageBody, in key: RunKey) async -> SendResult {
        guard let run = runs[key], let request = requests[run.request] else { return .ended }
        let hub = run.role == .hub ? localPeer : key.peer
        guard Self.passesGate(body, profile: request.profile, me: localPeer, hub: hub, member: run.role == .hub ? key.peer : localPeer, now: clock.now()) else {
            diagnostics.gateRefusals += 1
            end(key, .failed)
            return .ended
        }
        let context: OutboundContext = if case .psi = body { run.psiContext } else { .empty }
        let step = Step(run: run, request: request)
        let card = cards[key.peer]
        let chainedFrom = run.chainedFrom
        let result = await cancellable(run: key, request: run.request) { [outbox] in
            try await outbox.send(body, to: key.peer, conversation: key.conversation, recipientCard: card, context: context, skill: DownFor.ref, chainedFrom: chainedFrom)
        }
        switch result {
        case .success(let envelope):
            noteSent(envelope, in: key)
            return .sent
        case .failure(OutboxError.denied):
            // A privacy topic set to Never, or the on-device-only rule. Only
            // a send for the step the interaction is still on says anything
            // about it; one a newer proposal replaced while the send was in
            // flight is dropped (ADR 0011, amendment 14).
            guard let current = runs[key], let request = requests[current.request], Step(run: current, request: request) == step else { return .ended }
            blockedByPrivacy(run.request)
            return .ended
        case .failure(OutboxError.consentDeclined):
            // "Don't send": the coordinator applies the pass; nothing more
            // leaves for this request.
            endQuietly(run.request, .ownerPassed)
            return .ended
        case .failure(is OutboxError):
            end(key, .policy)
            return .ended
        case .failure(is CancellationError):
            if runs[key] != nil { end(key, .timedOut) }
            return .ended
        case .failure:
            return runs[key] == nil ? .ended : .lost
        }
    }

    /// The step a send was made for: the run's phase and terms and the
    /// interaction's proposal revision.
    struct Step: Equatable {
        let phase: Run.Phase
        let terms: Terms?
        let revision: UInt32?

        init(run: Run, request: Request) {
            phase = run.phase
            terms = run.terms
            revision = request.mirror.proposalRevision
        }
    }

    /// Sends outside a run's own steps: a cached reply replayed, or a "no
    /// plan" notice. Only for a request that is still live: nothing leaves
    /// for one that ended. Tracked by request, so ending it cancels the
    /// send. Failures are ignored; the peer's own deadline covers them.
    func deliver(_ body: MessageBody, to key: RunKey, for request: InteractionID, chainedFrom: ConversationID?, context: OutboundContext = .empty) async {
        guard requests[request] != nil else { return }
        let card = cards[key.peer]
        _ = await cancellable(run: nil, request: request) { [outbox] in
            try await outbox.send(body, to: key.peer, conversation: key.conversation, recipientCard: card, context: context, skill: DownFor.ref, chainedFrom: chainedFrom)
        }
    }

    func tell(_ notice: Notice, _ reason: Rejection.Reason) async {
        await deliver(.reject(Rejection(proposal: notice.lastInbound ?? MessageID(), reason: reason)), to: notice.key, for: notice.request, chainedFrom: notice.chainedFrom)
    }

    func replay(_ reply: Reply, answering envelope: Envelope, for request: InteractionID, chainedFrom: ConversationID?, context: OutboundContext) async {
        guard let body = try? reply.body(answering: envelope) else { return }
        // A replayed offer or acceptance is only worth sending while its
        // plan is still ahead.
        if let start = Self.planStart(of: body), !DownForProfile.hasNotStarted(start, now: clock.now()) { return }
        await deliver(body, to: RunKey(conversation: envelope.conversation, peer: envelope.sender), for: request, chainedFrom: chainedFrom, context: context)
    }

    private func noteSent(_ envelope: Envelope, in key: RunKey) {
        switch envelope.body {
        case .query(let query): runs[key]?.queries[envelope.id] = query.issue
        case .propose: runs[key]?.proposalEnvelopes.append(envelope.id)
        default: break
        }
    }

    /// The gate every outbound value of a live run passes (ADR 0121, item 5):
    /// plans must have the Down for... shape and meet the owner's limits;
    /// query and answer values must meet them too.
    static func passesGate(_ body: MessageBody, profile: DownForProfile, me: PeerID, hub: PeerID, member: PeerID, now: Date) -> Bool {
        switch body {
        case .propose(let proposal): profile.permits(proposal.terms, me: me, hub: hub, member: member, now: now)
        case .accept(let acceptance): profile.permits(acceptance.terms, me: me, hub: hub, member: member, now: now)
        case .query(let query): profile.permits(query.issue, query.candidates)
        case .answer(let answer): answer.acceptable.map { profile.permits(answer.issue, $0) } ?? true
        case .psi, .reject: true
        case .counter, .hello: false
        }
    }

    static func planStart(of body: MessageBody) -> TimeSlot? {
        switch body {
        case .propose(let proposal): DownForProfile.slot(of: proposal.terms)
        case .accept(let acceptance): DownForProfile.slot(of: acceptance.terms)
        default: nil
        }
    }

    /// Runs `work` in its own task on behalf of run `key`. If the run ends
    /// first, the task is cancelled and this returns a cancellation error at
    /// once, so a stalled model call or an unanswered consent sheet never
    /// holds up the friend's queue or outlives its deadline. The Outbox
    /// checks cancellation after consent and before the transport, so a
    /// cancelled send never leaves.
    func cancellable<T: Sendable>(run key: RunKey?, request: InteractionID?, _ work: @escaping @Sendable () async throws -> T) async -> Result<T, any Error> {
        let token = UUID()
        return await withCheckedContinuation { (waiter: CheckedContinuation<Result<T, any Error>, Never>) in
            let task = Task { [weak self] in
                let result: Result<T, any Error>
                do {
                    result = .success(try await work())
                } catch {
                    result = .failure(error)
                }
                await self?.finishWork(token) { waiter.resume(returning: result) }
            }
            pendingWork[token] = PendingWork(run: key, request: request, task: task, abandon: { waiter.resume(returning: .failure(CancellationError())) })
        }
    }

    private func finishWork(_ token: UUID, resume: @Sendable () -> Void) {
        // Resume only if nobody abandoned it first: exactly once either way.
        guard pendingWork.removeValue(forKey: token) != nil else { return }
        resume()
    }

    func cancelWork(where matches: (PendingWork) -> Bool) {
        for (token, pending) in pendingWork where matches(pending) {
            pendingWork[token] = nil
            pending.task.cancel()
            pending.abandon()
        }
    }

    // MARK: - Deadlines

    /// Starts a step's deadline: `attemptLimit` ticks from now. Nothing is
    /// resent until the step's bodies have gone out once.
    func beginStep(_ key: RunKey, attemptLimit: Int, backsOff: Bool = false) {
        guard runs[key] != nil else { return }
        runs[key]?.outstanding = []
        runs[key]?.attempts = 1
        runs[key]?.attemptLimit = attemptLimit
        runs[key]?.interval = configuration.retryInterval
        runs[key]?.backsOff = backsOff
        armTimer(key)
    }

    /// Restarts the current deadline without touching what is resent, when
    /// the peer shows it is still there.
    func refreshDeadline(_ key: RunKey) {
        guard runs[key] != nil else { return }
        runs[key]?.attempts = 1
        runs[key]?.interval = configuration.retryInterval
        armTimer(key)
    }

    /// Ticks a member allows without hearing from the starter while a
    /// proposal waits on people: about twice the owner window.
    var silenceLimit: Int {
        let window = Double(configuration.ownerWindow.components.seconds) + Double(configuration.ownerWindow.components.attoseconds) / 1e18
        let backoff = Double(configuration.maxBackoff.components.seconds) + Double(configuration.maxBackoff.components.attoseconds) / 1e18
        return Int((2 * window / backoff).rounded(.up)) + 8
    }

    private func armTimer(_ key: RunKey) {
        guard let run = runs[key] else { return }
        let token = run.timerToken + 1
        runs[key]?.timerToken = token
        timers[key]?.cancel()
        let interval = run.interval
        timers[key] = Task { [weak self, clock] in
            do { try await clock.sleep(interval) } catch { return }
            await self?.deadlineTick(key, token: token)
        }
    }

    /// Runs on the actor directly, not on the friend's queue, so a deadline
    /// fires even while that queue waits on a stalled model call or consent
    /// sheet; ending the run then cancels that work.
    private func deadlineTick(_ key: RunKey, token: Int) {
        guard let run = runs[key], run.timerToken == token else { return }
        guard run.attempts < run.attemptLimit else { return end(key, .timedOut) }
        runs[key]?.attempts += 1
        if run.backsOff { runs[key]?.interval = min(run.interval * 2, configuration.maxBackoff) }
        armTimer(key)
        if !run.outstanding.isEmpty, let current = runs[key] {
            enqueue(.resend(key, token: current.timerToken), for: key.peer)
        }
    }

    private func resend(_ key: RunKey, token: Int) async {
        guard let run = runs[key], run.timerToken == token else { return }
        for body in run.outstanding {
            guard await send(body, in: key) != .ended, runs[key] != nil else { return }
        }
    }

    private func scheduleRetry(_ id: InteractionID, with peer: PeerID) {
        let pause = configuration.retryInterval * configuration.maxAttempts
        Task { [weak self, clock] in
            do { try await clock.sleep(pause) } catch { return }
            await self?.enqueue(.start(id), for: peer)
        }
    }

    // MARK: - Ending runs

    /// Ends a run without telling anyone. With `react`, the request then
    /// moves on: a starter re-plans or settles, a member goes back to its
    /// own group or ends.
    func end(_ key: RunKey, _ outcome: RunOutcome, react: Bool = true) {
        guard let run = runs.removeValue(forKey: key) else { return }
        timers.removeValue(forKey: key)?.cancel()
        cancelWork { $0.run == key }
        diagnostics.outcomes[outcome, default: 0] += 1
        if outcome == .matched {
            finished[key] = Finished(request: run.request, replies: run.replies, chainedFrom: run.chainedFrom)
            finishedOrder.append(key)
            while finishedOrder.count > configuration.maxFinishedRuns { finished[finishedOrder.removeFirst()] = nil }
        }
        guard requests[run.request] != nil else { return }
        if outcome.settles { requests[run.request]?.settled.insert(key.peer) }
        // A friend who did not answer may simply not be down yet: try again
        // after a pause, within the run cap. Neither side restarts a run
        // otherwise, so without this two timed-out runs would wait forever.
        if outcome == .timedOut, run.role == .hub { scheduleRetry(run.request, with: key.peer) }
        guard react, outcome != .matched else { return }
        switch run.role {
        case .hub: hubLost(key.peer, in: run.request)
        case .member: memberRunEnded(key, request: run.request)
        }
    }
}
