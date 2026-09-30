import Foundation
import StarlingCore

public enum DownError: Error, Hashable, Sendable {
    /// The intent's expiry is not in the future.
    case expired
    /// The owner's rules leave no free half-hour before the intent expires.
    case noAvailableTime
}

/// The Down? feature (ARCHITECTURE section 7, ADR 0120).
///
/// For each reachable paired friend: a PSI run over free half-hours; if it
/// finds shared time, queries on activity and budget, then offers; and only
/// when both sides have accepted the same plan, `DownEvent.matched` on both
/// phones. Anything else ends silently.
///
/// The app owns the single `Inbox` loop and passes every `InboxEvent` to
/// `handle(_:)`. Every send goes through the `Outbox`.
public actor DownNegotiator: DownService {
    public nonisolated let events: AsyncStream<DownEvent>
    private let continuation: AsyncStream<DownEvent>.Continuation

    let localPeer: PeerID
    let outbox: Outbox
    let pairedPeers: any PairedPeerStore
    let model: any AgentModel
    let psi: any PSIProvider
    let clock: DownClock
    let timeZone: TimeZone
    let configuration: DownConfiguration

    private struct ActiveIntent {
        let intent: DownIntent
        let generation: Int
        let expiry: Task<Void, Never>
    }

    private enum Work: Sendable {
        case start(generation: Int)
        case message(Envelope)
        case timer(ConversationID, token: Int)
    }

    private var intent: ActiveIntent?
    private var generation = 0
    private var reachable: Set<PeerID> = []
    private var cards: [PeerID: AgentCard] = [:]

    private var workers: [PeerID: (queue: AsyncStream<Work>.Continuation, task: Task<Void, Never>)] = [:]
    private var timers: [ConversationID: Task<Void, Never>] = [:]
    /// Sends in the Outbox (possibly waiting on policy or the owner's consent).
    /// Ending their conversation cancels them and releases the waiting worker.
    private var pendingSends: [UUID: PendingSend] = [:]

    private struct PendingSend {
        let conversation: ConversationID
        let task: Task<Void, Never>
        let waiter: CheckedContinuation<Result<Envelope, any Error>, Never>
    }
    var conversations: [ConversationID: DownConversation] = [:]
    private var activeByPeer: [PeerID: ConversationID] = [:]
    private var finished: [ConversationID: Finished] = [:]

    /// What stays of an ended conversation, so a late retry of the peer's
    /// last message can still be answered, but only when that is safe.
    private struct Finished {
        let peer: PeerID
        let replies: [DownSignature: DownReply]
        let psiContext: OutboundContext
        let outcome: DownOutcome
        let generation: Int
    }
    private var finishedOrder: [ConversationID] = []

    /// Per intent: PSI runs with each peer, and peers we are done with.
    private var runs: [PeerID: Int] = [:]
    private var settled: Set<PeerID> = []

    /// For tests and logs. Never shown to the owner or sent.
    struct Diagnostics: Sendable {
        var outcomes: [DownOutcome: Int] = [:]
        var modelCalls = 0
        /// Outbound values the final gate refused. Anything above zero is a
        /// bug upstream, caught before it reached the Outbox.
        var gateRefusals = 0
    }

    private(set) var diagnostics = Diagnostics()

    /// The app builds the `Outbox` (it owns the policy and the consent
    /// sheet) and passes it here, then feeds `handle(_:)` from its Inbox loop.
    ///
    /// - Parameters:
    ///   - localPeer: This device's ID (the Outbox's transport's `localPeer`),
    ///     used to break ties when two friends start at once.
    ///   - pairedPeers: Only these peers ever receive Down traffic, and only
    ///     their messages are handled.
    public init(
        localPeer: PeerID,
        outbox: Outbox,
        pairedPeers: any PairedPeerStore,
        model: any AgentModel,
        psi: any PSIProvider,
        clock: DownClock = .system,
        timeZone: TimeZone = .current,
        configuration: DownConfiguration = DownConfiguration()
    ) {
        self.localPeer = localPeer
        self.outbox = outbox
        self.pairedPeers = pairedPeers
        self.model = model
        self.psi = psi
        self.clock = clock
        self.timeZone = timeZone
        self.configuration = configuration
        (events, continuation) = AsyncStream.makeStream(of: DownEvent.self)
    }

    /// The PSI provider in use. While `isPrivate` is false, the consent
    /// sheet should say that matching does not hide the owner's free times.
    public nonisolated var psiProvider: PSIProviderDescriptor { psi.descriptor }

    // MARK: - DownService

    public func setIntent(_ newIntent: DownIntent) async throws {
        let now = clock.now()
        guard newIntent.expiresAt.date > now else { throw DownError.expired }
        let profile = DownProfile(intent: newIntent, now: now, timeZone: timeZone)
        guard !profile.tokens.slots.isEmpty else { throw DownError.noAvailableTime }

        endEverything()
        generation += 1
        let current = generation
        let delay = newIntent.expiresAt.date.timeIntervalSince(now)
        let expiry = Task { [weak self, clock] in
            do { try await clock.sleep(.milliseconds(Int64(delay * 1000))) } catch { return }
            await self?.expire(generation: current)
        }
        intent = ActiveIntent(intent: newIntent, generation: current, expiry: expiry)
        runs = [:]
        settled = []

        let friends = ((try? await pairedPeers.all()) ?? []).map(\.id).filter(reachable.contains)
        guard intent?.generation == current else { return }
        continuation.yield(.checking(friends: friends.count))
        for friend in friends { enqueue(.start(generation: current), for: friend) }
    }

    public func clearIntent() async {
        guard intent != nil else { return }
        endEverything()
        generation += 1
        continuation.yield(.ended(.withdrawn))
    }

    /// Every event from the app's Inbox loop (`DownService`). Returns at once;
    /// work for each friend runs in order on its own task, so a consent sheet
    /// or a slow model call never holds up the loop.
    public func handle(_ event: InboxEvent) {
        switch event {
        case .peerAvailable(let peer):
            reachable.insert(peer)
            if let intent { enqueue(.start(generation: intent.generation), for: peer) }
        case .peerUnavailable(let peer):
            reachable.remove(peer)
        case .message(let envelope):
            if case .hello(let card) = envelope.body {
                cards[envelope.sender] = card
            } else {
                enqueue(.message(envelope), for: envelope.sender)
            }
        case .dropped:
            break
        }
    }

    /// Ends every conversation silently and finishes `events`.
    public func shutdown() {
        endEverything()
        generation += 1
        for worker in workers.values {
            worker.queue.finish()
            worker.task.cancel()
        }
        workers = [:]
        continuation.finish()
    }

    // MARK: - Intent lifecycle

    private func expire(generation expired: Int) {
        guard intent?.generation == expired else { return }
        endEverything()
        generation += 1
        continuation.yield(.ended(.expired))
    }

    private func endEverything() {
        for id in Array(conversations.keys) { end(id, .withdrawn) }
        // Replies for finished conversations may still be in the Outbox.
        cancelSends { _ in true }
        intent?.expiry.cancel()
        intent = nil
    }

    func isReachable(_ peer: PeerID) -> Bool { reachable.contains(peer) }

    // MARK: - Work queues

    /// Bounds the per-peer queues, since `handle` runs before the paired
    /// check. Once the secure channel drops unknown keys below the Inbox
    /// (ADR 0003), only paired friends get this far anyway.
    static let maxWorkers = 256

    private func enqueue(_ work: Work, for peer: PeerID) {
        if workers[peer] == nil {
            guard workers.count < Self.maxWorkers else { return }
            let (stream, queue) = AsyncStream.makeStream(of: Work.self)
            let task = Task { [weak self] in
                for await work in stream {
                    guard let self else { return }
                    await self.perform(work, peer: peer)
                }
            }
            workers[peer] = (queue, task)
        }
        workers[peer]?.queue.yield(work)
    }

    private func perform(_ work: Work, peer: PeerID) async {
        switch work {
        case .start(let generation): await initiate(with: peer, generation: generation)
        case .message(let envelope): await receive(envelope)
        case .timer(let id, let token): await timerFired(id, token: token)
        }
    }

    // MARK: - Starting a run

    private func initiate(with peer: PeerID, generation current: Int) async {
        guard canRun(with: peer, generation: current), activeByPeer[peer] == nil, reachable.contains(peer) else { return }
        // A friend whose card says it cannot do Down is not asked. No card
        // yet (the hello may still be in flight) is not a reason to skip.
        if let card = cards[peer], !card.capabilities.contains(.down) { return }
        guard await isPaired(peer), let profile = runProfile(), canRun(with: peer, generation: current), activeByPeer[peer] == nil else { return }

        let session: any PSISession
        let firstStep: PSIStep
        do {
            session = try psi.makeSession(role: .initiator, localSet: profile.tokens.elements, configuration: DownTokenSet.psiConfiguration())
            firstStep = try await session.start()
        } catch {
            record(.failed)
            return
        }
        guard canRun(with: peer, generation: current), activeByPeer[peer] == nil, case .send(let payload) = firstStep else { return }

        let conversation = DownConversation(
            id: ConversationID(), peer: peer, role: .initiator, generation: current,
            profile: profile, psiSessionID: UUID(), psi: session, provider: psi.descriptor
        )
        register(conversation)
        guard let frame = try? PSIFrame(session: conversation.psiSessionID, step: 0, payload: payload) else {
            end(conversation.id, .failed)
            return
        }
        await transmit([.psi(frame)], in: conversation.id, awaitingReply: true)
    }

    /// A peer started a run with us.
    func respond(to envelope: Envelope, frame: PSIFrame) async {
        let peer = envelope.sender
        guard frame.step == 0, let current = intent?.generation, canRun(with: peer, generation: current) else { return }
        if let existing = activeByPeer[peer], let mine = conversations[existing] {
            // Both started at once. The lower peer ID's run goes ahead.
            let simultaneous = mine.role == .initiator && mine.phase == .psi && mine.nextInboundPSIStep == 1
            guard simultaneous, peer < localPeer else { return }
            end(existing, .yielded)
            runs[peer, default: 1] -= 1
        }
        guard let profile = runProfile(),
              let session = try? psi.makeSession(role: .responder, localSet: profile.tokens.elements, configuration: DownTokenSet.psiConfiguration())
        else { return }
        let conversation = DownConversation(
            id: envelope.conversation, peer: peer, role: .responder, generation: current,
            profile: profile, psiSessionID: frame.session, psi: session, provider: psi.descriptor
        )
        register(conversation)
        await handlePSI(frame, in: conversation.id)
    }

    /// The intent as of now, so a run that starts late offers only slots
    /// still ahead (ADR 0120). Nil when none are left.
    private func runProfile() -> DownProfile? {
        guard let intent else { return nil }
        let profile = DownProfile(intent: intent.intent, now: clock.now(), timeZone: timeZone)
        return profile.tokens.slots.isEmpty ? nil : profile
    }

    private func canRun(with peer: PeerID, generation current: Int) -> Bool {
        intent?.generation == current && !settled.contains(peer) && runs[peer, default: 0] < configuration.maxRunsPerPeer
    }

    private func register(_ conversation: DownConversation) {
        conversations[conversation.id] = conversation
        activeByPeer[conversation.peer] = conversation.id
        runs[conversation.peer, default: 0] += 1
    }

    func isPaired(_ peer: PeerID) async -> Bool {
        ((try? await pairedPeers.peer(for: peer)) ?? nil) != nil
    }

    // MARK: - Inbound

    private func receive(_ envelope: Envelope) async {
        guard await isPaired(envelope.sender) else { return }
        let signature = DownSignature(envelope.body)

        if let conversation = conversations[envelope.conversation] {
            guard conversation.peer == envelope.sender else { return }
            guard conversation.generation == intent?.generation else {
                end(conversation.id, .withdrawn)
                return
            }
            if let signature, let reply = conversation.replies[signature] {
                await replay(reply, to: envelope)
                return
            }
            await dispatch(envelope, in: conversation.id)
        } else if let record = finished[envelope.conversation] {
            // Only a match under the intent that is still current is worth
            // repeating: the peer lost our confirmation (ADR 0120). After a
            // withdrawal, expiry, refusal, or failure, a replay would undo
            // the ending (or raise a declined consent sheet again).
            guard record.peer == envelope.sender, record.outcome == .matched, record.generation == intent?.generation,
                  let signature, let reply = record.replies[signature]
            else { return }
            await replay(reply, to: envelope)
        } else if case .psi(let frame) = envelope.body {
            await respond(to: envelope, frame: frame)
        }
    }

    private func replay(_ reply: DownReply, to envelope: Envelope) async {
        guard let body = try? reply.body(answering: envelope) else { return }
        _ = await send(body, to: envelope.sender, in: envelope.conversation, profile: nil)
    }

    // MARK: - Outbound

    /// Sends `bodies` in order, then arms the retry timer. With
    /// `awaitingReply`, the timer resends them; otherwise it only bounds how
    /// long we wait for the peer's next move.
    func transmit(_ bodies: [MessageBody], in id: ConversationID, awaitingReply: Bool) async {
        guard let conversation = conversations[id] else { return }
        for body in bodies {
            if await send(body, to: conversation.peer, in: id, profile: conversation.profile) == .ended { return }
        }
        guard var conversation = conversations[id] else { return }
        conversation.outstanding = awaitingReply ? bodies : []
        conversation.attempts = 1
        conversations[id] = conversation
        armTimer(id)
    }

    enum SendResult { case sent, lost, ended }

    /// The last check before the Outbox, and the only place Down calls it.
    /// `profile` is the gate to pass; nil only for a replay of a reply that
    /// already passed it. A gate refusal, a policy denial, or declined consent
    /// ends the conversation. A transport error is `.lost`: the retry timer
    /// covers lost frames.
    func send(_ body: MessageBody, to peer: PeerID, in id: ConversationID, profile: DownProfile?) async -> SendResult {
        if let profile, !Self.passesGate(body, profile: profile) {
            diagnostics.gateRefusals += 1
            end(id, .failed)
            return .ended
        }
        // Every PSI step tells the policy what it discloses (Core v1.1); a
        // policy refuses a PSI step without this.
        var context = OutboundContext.empty
        if case .psi = body {
            guard let psiContext = conversations[id]?.psiContext ?? finished[id]?.psiContext else { return .ended }
            context = psiContext
        }
        do {
            let envelope = try await cancellableSend(body, to: peer, in: id, context: context).get()
            noteSent(envelope)
            return .sent
        } catch is OutboxError {
            // Policy or the owner said no; do not ask again during this intent.
            settled.insert(peer)
            end(id, .policy)
            return .ended
        } catch {
            return conversations[id] == nil && finished[id] == nil ? .ended : .lost
        }
    }

    /// Runs one `Outbox.send` in its own task, so `end(_:_:)` can cancel it
    /// while it waits on policy or consent. The Outbox checks cancellation
    /// after consent and again right before the transport, so a cancelled
    /// send never leaves. Cancelling also resumes this call at once, so the
    /// friend's work queue is not held up by a sheet nobody will answer.
    private func cancellableSend(_ body: MessageBody, to peer: PeerID, in id: ConversationID, context: OutboundContext) async -> Result<Envelope, any Error> {
        let key = UUID()
        let card = cards[peer]
        return await withCheckedContinuation { waiter in
            let task = Task { [weak self, outbox] in
                let result: Result<Envelope, any Error>
                do {
                    result = .success(try await outbox.send(body, to: peer, conversation: id, recipientCard: card, context: context))
                } catch {
                    result = .failure(error)
                }
                await self?.finishSend(key, result)
            }
            pendingSends[key] = PendingSend(conversation: id, task: task, waiter: waiter)
        }
    }

    private func finishSend(_ key: UUID, _ result: Result<Envelope, any Error>) {
        pendingSends.removeValue(forKey: key)?.waiter.resume(returning: result)
    }

    private func cancelSends(where matches: (ConversationID) -> Bool) {
        for (key, pending) in pendingSends where matches(pending.conversation) {
            pendingSends[key] = nil
            pending.task.cancel()
            pending.waiter.resume(returning: .failure(CancellationError()))
        }
    }

    static func passesGate(_ body: MessageBody, profile: DownProfile) -> Bool {
        func clean(_ issue: IssueKey, _ value: IssueValue) -> Bool {
            guard let terms = try? Terms([issue: value]) else { return false }
            return profile.constraints.violations(of: terms, timeZone: profile.timeZone).isEmpty
        }
        switch body {
        case .propose(let proposal), .counter(let proposal):
            return profile.permits(proposal.terms)
        case .accept(let acceptance):
            guard let (plan, _) = DownProfile.split(acceptance.terms) else { return false }
            return profile.permits(plan)
        case .query(let query):
            return clean(query.issue, query.candidates)
        case .answer(let answer):
            guard let value = answer.acceptable else { return true }
            return clean(answer.issue, value)
        case .psi, .reject, .hello:
            return true
        }
    }

    private func noteSent(_ envelope: Envelope) {
        guard var conversation = conversations[envelope.conversation] else { return }
        switch envelope.body {
        case .query(let query):
            conversation.queries[envelope.id] = query.issue
        case .propose(let proposal), .counter(let proposal):
            if conversation.myOffer?.round == proposal.round { conversation.myOffer?.envelopes.insert(envelope.id) }
        default:
            break
        }
        conversations[envelope.conversation] = conversation
    }

    // MARK: - Timers

    private func armTimer(_ id: ConversationID) {
        guard var conversation = conversations[id] else { return }
        conversation.timerToken += 1
        conversations[id] = conversation
        let token = conversation.timerToken
        let peer = conversation.peer
        timers[id]?.cancel()
        timers[id] = Task { [weak self, clock, configuration] in
            do { try await clock.sleep(configuration.retryInterval) } catch { return }
            await self?.enqueue(.timer(id, token: token), for: peer)
        }
    }

    private func timerFired(_ id: ConversationID, token: Int) async {
        guard let conversation = conversations[id], conversation.timerToken == token else { return }
        guard conversation.generation == intent?.generation else {
            end(id, .withdrawn)
            return
        }
        guard conversation.attempts < configuration.maxAttempts else {
            end(id, .timedOut)
            return
        }
        for body in conversation.outstanding {
            if await send(body, to: conversation.peer, in: id, profile: conversation.profile) == .ended { return }
        }
        guard var current = conversations[id], current.timerToken == token else { return }
        current.attempts += 1
        conversations[id] = current
        armTimer(id)
    }

    // MARK: - Ending

    /// Ends a conversation without telling the owner anything. Its replies
    /// are kept, but only a match replays them (see `receive`).
    func end(_ id: ConversationID, _ outcome: DownOutcome) {
        guard let conversation = conversations.removeValue(forKey: id) else { return }
        timers.removeValue(forKey: id)?.cancel()
        cancelSends { $0 == id }
        if activeByPeer[conversation.peer] == id { activeByPeer[conversation.peer] = nil }
        switch outcome {
        case .matched, .noOverlap, .rejected, .policy, .failed:
            if conversation.generation == intent?.generation { settled.insert(conversation.peer) }
        case .timedOut, .withdrawn, .yielded:
            break
        }
        record(outcome)

        finished[id] = Finished(
            peer: conversation.peer, replies: conversation.replies, psiContext: conversation.psiContext,
            outcome: outcome, generation: conversation.generation
        )
        finishedOrder.append(id)
        while finishedOrder.count > configuration.maxFinishedConversations {
            finished[finishedOrder.removeFirst()] = nil
        }
    }

    private func record(_ outcome: DownOutcome) {
        diagnostics.outcomes[outcome, default: 0] += 1
    }

    func noteModelCall() {
        diagnostics.modelCalls += 1
    }

    func notifyMatch(with peer: PeerID, plan: Terms, peerLevel: DownLevel, ownLevel: DownLevel) {
        continuation.yield(.matched(DownMatch(peer: peer, terms: plan, bothDown: ownLevel == .down && peerLevel == .down)))
    }
}
