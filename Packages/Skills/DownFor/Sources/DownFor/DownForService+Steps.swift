import Foundation
import StarlingCore
import StarlingNegotiation

// The protocol steps (ADR 0210). Each handler runs on the friend's own
// queue, so steps for one friend never interleave. Other actor work can run
// at every `await`, so handlers re-read state afterwards and stop if the run
// has ended.

extension DownForService {
    // MARK: - Starting runs

    /// Starts the request's run with `peer`, as the starter, if the request
    /// is still gathering its own group.
    func initiate(_ id: InteractionID, with peer: PeerID) async {
        guard canStart(id, with: peer), let request = requests[id] else { return }
        let tokens = request.profile.tokens(now: clock.now())
        guard !tokens.slots.isEmpty else { return }
        let session: any PSISession
        let first: PSIStep
        do {
            session = try psi.makeSession(role: .initiator, localSet: tokens.elements, configuration: SlotTokenSet.psiConfiguration())
            first = try await session.start()
        } catch {
            diagnostics.outcomes[.failed, default: 0] += 1
            return
        }
        guard canStart(id, with: peer), case .send(let payload) = first else { return }
        let key = RunKey(conversation: request.conversation, peer: peer)
        let run = Run(key: key, request: id, role: .hub, chainedFrom: request.record.chainedFrom, psiSessionID: UUID(), psi: session, tokens: tokens, provider: psi.descriptor)
        runs[key] = run
        requests[id]?.runs[peer, default: 0] += 1
        guard let frame = try? PSIFrame(session: run.psiSessionID, step: 0, payload: payload) else { return end(key, .failed) }
        await transmit([.psi(frame)], in: key, awaitingReply: true)
    }

    private func canStart(_ id: InteractionID, with peer: PeerID) -> Bool {
        guard let request = requests[id], request.isGathering, request.engagement == .hub, request.group == nil,
              request.record.participants.contains(peer), !request.settled.contains(peer), !request.unsupported.contains(peer),
              reachable.contains(peer), request.runs[peer, default: 0] < configuration.maxRunsPerPeer
        else { return false }
        // One run per friend per request, in either role.
        return !runs.values.contains { $0.request == id && $0.key.peer == peer }
    }

    /// A friend started a run with us. We answer only from an open request
    /// of our own that includes them, and only if their `PeerID` is lower:
    /// otherwise our own run carries the pair, so we make sure it runs.
    /// Nobody without an open request answers, sees a sheet, or runs the
    /// model (ADR 0120, item 3).
    func respond(to envelope: Envelope, frame: PSIFrame) async {
        let peer = envelope.sender
        guard frame.step == 0 else { return }
        let candidates = requests.values
            .filter { $0.isGathering && $0.group == nil && $0.record.participants.contains(peer) && !$0.settled.contains(peer) && !$0.unsupported.contains(peer) }
            .sorted { $0.mirror.createdAt < $1.mirror.createdAt }
        for request in candidates {
            if localPeer < peer {
                enqueue(.start(request.id), for: peer)
                return
            }
            // Committed to a lower starter already: that group comes first.
            if case .member(let current) = request.engagement, current.peer < peer { continue }
            guard request.runs[peer, default: 0] < configuration.maxRunsPerPeer else { continue }
            // Our own run with this friend gives way to theirs.
            for key in runs.keys where runs[key]?.request == request.id && key.peer == peer {
                end(key, .yielded, react: false)
                requests[request.id]?.runs[peer, default: 1] -= 1
            }
            let tokens = request.profile.tokens(now: clock.now())
            guard !tokens.slots.isEmpty,
                  let session = try? psi.makeSession(role: .responder, localSet: tokens.elements, configuration: SlotTokenSet.psiConfiguration())
            else { return }
            let key = RunKey(conversation: envelope.conversation, peer: peer)
            var run = Run(key: key, request: request.id, role: .member, chainedFrom: envelope.chainedFrom, psiSessionID: frame.session, psi: session, tokens: tokens, provider: psi.descriptor)
            run.lastInbound = envelope.id
            runs[key] = run
            requests[request.id]?.runs[peer, default: 0] += 1
            // The reply may wait on consent; bound it like any other step.
            beginStep(key, attemptLimit: configuration.maxAttempts)
            await handlePSI(frame, in: key)
            return
        }
    }

    // MARK: - Inbound

    func receive(_ envelope: Envelope) async {
        let key = RunKey(conversation: envelope.conversation, peer: envelope.sender)
        let signature = Signature(envelope.body)
        if let run = runs[key] {
            runs[key]?.lastInbound = envelope.id
            // The starter is still there: a member's wait starts over.
            if run.role == .member, run.phase == .proposed || run.phase == .accepted { refreshDeadline(key) }
            if let signature, let reply = run.replies[signature] {
                if case .offer = signature { runs[key]?.proposalEnvelopes.append(envelope.id) }
                let context: OutboundContext = if case .psi = reply { run.psiContext } else { .empty }
                await replay(reply, answering: envelope, chainedFrom: run.chainedFrom, context: context)
                return
            }
            await dispatch(envelope, in: key)
        } else if let record = finished[key] {
            // Only a plan is worth repeating: the peer lost our last message.
            guard let signature, let reply = record.replies[signature] else { return }
            await replay(reply, answering: envelope, chainedFrom: record.chainedFrom, context: .empty)
        } else if case .psi(let frame) = envelope.body {
            await respond(to: envelope, frame: frame)
        }
    }

    private func dispatch(_ envelope: Envelope, in key: RunKey) async {
        guard let run = runs[key] else { return }
        switch envelope.body {
        case .psi(let frame): await handlePSI(frame, in: key)
        case .query(let query): await handleQuery(query, envelope: envelope, in: key)
        case .answer(let answer): handleAnswer(answer, in: key)
        case .propose(let proposal): handleProposal(proposal, envelope: envelope, in: key)
        case .accept(let acceptance):
            if run.role == .hub { handleAccept(acceptance, in: key) } else { handleConfirmation(acceptance, in: key) }
        case .reject: end(key, .rejected)
        case .counter, .hello: break
        }
    }

    // MARK: - Mutual interest (PSI)

    private func handlePSI(_ frame: PSIFrame, in key: RunKey) async {
        guard let run = runs[key], run.phase == .psi, frame.session == run.psiSessionID,
              frame.step == run.nextInboundPSIStep, frame.step < UInt8.max - 1
        else { return }
        let step: PSIStep
        do {
            step = try await run.psi.handle(frame.payload)
        } catch {
            // Oversized or malformed peer set: stop without a word.
            return end(key, .failed)
        }
        guard runs[key]?.phase == .psi else { return }
        let signature = Signature.psi(step: frame.step, payload: frame.payload)
        switch step {
        case .send(let payload):
            guard let reply = try? PSIFrame(session: run.psiSessionID, step: frame.step + 1, payload: payload) else { return end(key, .failed) }
            runs[key]?.replies[signature] = .psi(reply)
            runs[key]?.nextInboundPSIStep = frame.step + 2
            await transmit([.psi(reply)], in: key, awaitingReply: true)
        case .finish(let payload, let result):
            if let payload {
                guard let reply = try? PSIFrame(session: run.psiSessionID, step: frame.step + 1, payload: payload) else { return end(key, .failed) }
                runs[key]?.replies[signature] = .psi(reply)
                guard await send(.psi(reply), in: key) != .ended else { return }
            }
            await finishPSI(result, in: key)
        }
    }

    private func finishPSI(_ result: PSIResult?, in key: RunKey) async {
        guard var run = runs[key] else { return }
        switch result {
        case .intersection(let shared)?:
            let slots = run.tokens.slots(in: shared)
            guard !slots.isEmpty else { return end(key, .noOverlap) }
            run.overlap = slots
        case .cardinality(let count)?:
            guard count > 0 else { return end(key, .noOverlap) }
        case nil:
            break
        }
        run.phase = .details
        runs[key] = run
        switch run.role {
        case .hub:
            // The starter plans the time, so it must know the shared slots.
            guard run.overlap != nil else { return end(key, .failed) }
            await askDetails(in: key)
        case .member:
            // One deadline for the whole wait: the starter gathers every
            // friend before it proposes.
            await transmit([], in: key, awaitingReply: false, attemptLimit: 4 * configuration.maxAttempts)
        }
    }

    // MARK: - Details, only after overlap

    private func askDetails(in key: RunKey) async {
        guard let run = runs[key], let request = requests[run.request] else { return }
        var bodies: [MessageBody] = []
        var pending: Set<IssueKey> = []
        let liked = Array(request.profile.liked.prefix(ProtocolLimits.maxKeywordsPerValue))
        if let query = try? Query(issue: .activity, candidates: .keywords(liked)) {
            bodies.append(.query(query))
            pending.insert(.activity)
        }
        if let cap = request.profile.budgetCap, let query = try? Query(issue: .budget, candidates: .amount(cap)) {
            bodies.append(.query(query))
            pending.insert(.budget)
        }
        runs[key]?.pendingQueries = pending
        await transmit(bodies, in: key, awaitingReply: true)
    }

    private func handleQuery(_ query: Query, envelope: Envelope, in key: RunKey) async {
        // A starter asks about activity and budget, once each. Anything else,
        // or a second query on the same issue, gets no answer and no model call.
        guard let run = runs[key], run.role == .member, run.phase == .details,
              [IssueKey.activity, .budget].contains(query.issue), !run.answeredIssues.contains(query.issue),
              engage(run.request, in: key), let profile = requests[run.request]?.profile
        else { return }
        runs[key]?.answeredIssues.insert(query.issue)

        let value: IssueValue?
        switch (query.issue, query.candidates) {
        case (.activity, .keywords(let candidates)):
            // Before the model: it never sees a keyword the owner avoids.
            let usable = candidates.filter { !profile.avoided.contains($0) }
            var matches: [KeywordMatch] = []
            if !profile.liked.isEmpty, !usable.isEmpty {
                diagnostics.modelCalls += 1
                let liked = profile.liked
                matches = (try? await cancellable(run: key, request: run.request) { [model] in try await model.match(wanted: liked, offered: usable).value }.get()) ?? []
                guard runs[key] != nil else { return }
            }
            // After the model: code decides what counts.
            value = .keywords(profile.acceptableActivities(candidates: candidates, matches: matches))
        case (.budget, .amount(let amount)):
            value = profile.budgetAnswer(for: amount).map(IssueValue.amount)
        default:
            value = nil
        }

        let reply = Reply.answer(issue: query.issue, value: value)
        guard runs[key] != nil, let body = try? reply.body(answering: envelope) else { return }
        runs[key]?.replies[.query(query)] = reply
        await transmit([body], in: key, awaitingReply: false, keepDeadline: true)
    }

    /// Commits the request to the starter of run `key`, if it may: a request
    /// joins at most one group, and prefers the lowest starter. Joining
    /// another starter's group stops the request's own group, and moving to
    /// a lower starter leaves a higher one. Each friend left behind is told
    /// "no plan". A request with a card from a group stays with it.
    private func engage(_ id: InteractionID, in key: RunKey) -> Bool {
        guard let request = requests[id], request.group == nil else { return false }
        switch request.engagement {
        case .member(let current) where current == key:
            return true
        case .member(let current):
            guard key.peer < current.peer, request.mirror.proposal == nil else { return false }
            if let old = runs[current] { enqueue(.notify(old.notice, .noOverlap), for: current.peer) }
            requests[id]?.engagement = .member(key)
            end(current, .yielded, react: false)
        case .hub:
            requests[id]?.engagement = .member(key)
            for other in runs.values where other.request == id && other.role == .hub {
                if other.phase != .psi { enqueue(.notify(other.notice, .noOverlap), for: other.key.peer) }
                end(other.key, .yielded, react: false)
            }
        }
        return true
    }

    private func handleAnswer(_ answer: Answer, in key: RunKey) {
        guard var run = runs[key], run.role == .hub, run.phase == .details,
              let issue = run.queries[answer.query], answer.issue == issue, run.pendingQueries.contains(issue)
        else { return }
        switch (issue, answer.acceptable) {
        case (.activity, .keywords(let keywords)?): run.activityAnswer = keywords
        case (.activity, _): run.activityAnswer = []
        case (.budget, .amount(let amount)?): run.budgetAnswer = amount
        default: break
        }
        run.pendingQueries.remove(issue)
        if run.pendingQueries.isEmpty {
            // Answers are in. Nothing to resend; the group decision is local.
            run.phase = .ready
            run.outstanding = []
            run.timerToken += 1
            timers.removeValue(forKey: key)?.cancel()
        }
        runs[key] = run
        if run.phase == .ready { considerProposing(run.request) }
    }

    // MARK: - Member: proposals and confirmation

    private func handleProposal(_ proposal: Proposal, envelope: Envelope, in key: RunKey) {
        guard let run = runs[key], run.role == .member, [.details, .proposed, .accepted].contains(run.phase),
              let request = requests[run.request], request.engagement == .member(key)
        else { return }
        let terms = proposal.terms
        guard request.profile.permits(terms, me: localPeer, hub: key.peer, member: localPeer, now: clock.now()) else {
            // Not a plan this owner can be in: no card, and the starter
            // carries on without us.
            enqueue(.notify(run.notice, .policy), for: key.peer)
            return end(key, .rejected)
        }
        if run.terms == terms {
            // A resend of the card the owner is looking at.
            runs[key]?.proposalEnvelopes.append(envelope.id)
            return
        }
        let revision = (request.mirror.proposalRevision ?? 0) + 1
        let roster = DownForProfile.roster(of: terms, hub: key.peer, member: localPeer) ?? []
        let card = SkillProposal(revision: revision, participants: roster, terms: terms, plan: DownForProfile.plan(from: terms, origin: key.conversation, hub: key.peer, member: localPeer))
        // Behind a consent sheet the card cannot show yet; the starter's
        // next resend brings it back.
        guard report(run.request, .proposalReady(card)) else { return }
        if let old = run.terms { runs[key]?.replies[.offer(old)] = nil }
        runs[key]?.terms = terms
        runs[key]?.accepted = false
        runs[key]?.phase = .proposed
        runs[key]?.proposalEnvelopes = [envelope.id]
        beginStep(key, attemptLimit: silenceLimit, backsOff: true)
    }

    /// The owner said "I'm in" on a member's card.
    func memberAccepted(_ id: InteractionID, in key: RunKey) {
        guard let run = runs[key], run.phase == .proposed, let terms = run.terms else { return }
        runs[key]?.accepted = true
        runs[key]?.phase = .accepted
        // A resend of the same proposal gets the same "I'm in".
        runs[key]?.replies[.offer(terms)] = .accept(terms)
        enqueue(.act(key, .accept), for: key.peer)
    }

    private func handleConfirmation(_ acceptance: Acceptance, in key: RunKey) {
        guard let run = runs[key], run.phase == .accepted, let terms = run.terms, acceptance.terms == terms,
              let revision = requests[run.request]?.mirror.proposalRevision
        else { return }
        // Everyone in the plan said yes to exactly these terms.
        guard report(run.request, .everyoneConfirmed(revision: revision)) else { return }
        produceArtifacts(run.request, terms: terms, origin: key.conversation, peer: key.peer)
        end(key, .matched)
        armPlanEnd(run.request)
    }

    /// A member's run ended without a plan. With a card already shown, the
    /// request ends as nobody up; otherwise it goes back to its own group.
    func memberRunEnded(_ key: RunKey, request id: InteractionID) {
        guard let request = requests[id] else { return }
        // A run we were only answering: our own group may go ahead now.
        guard request.engagement == .member(key) else { return considerProposing(id) }
        if request.mirror.proposal != nil {
            endRequest(id, with: .noAgreement, telling: nil)
            return
        }
        requests[id]?.engagement = .hub
        for peer in request.record.participants { enqueue(.start(id), for: peer) }
    }

    /// The plan and its people, built the same way on every phone. `peer`
    /// is the other end of the run that confirmed it; the starter is always
    /// first.
    func produceArtifacts(_ id: InteractionID, terms: Terms, origin: ConversationID, peer: PeerID) {
        let isHub = requests[id]?.conversation == origin
        let hub = isHub ? localPeer : peer
        let member = isHub ? peer : localPeer
        guard let plan = DownForProfile.plan(from: terms, origin: origin, hub: hub, member: member) else { return }
        produce(id, .plan(plan))
        produce(id, .attendees(plan.attendees))
    }

    // MARK: - Owner actions sent on the friend's queue

    func act(_ action: Action, in key: RunKey) async {
        guard let run = runs[key], let request = requests[run.request] else { return }
        switch action {
        case .propose:
            guard run.role == .hub, run.phase == .proposed, let terms = run.terms, let group = request.group,
                  let proposal = try? Proposal(round: UInt16(group.revision - 1), terms: terms)
            else { return }
            await transmit([.propose(proposal)], in: key, awaitingReply: true, attemptLimit: .max, backsOff: true)
        case .accept:
            guard run.role == .member, run.phase == .accepted, let terms = run.terms, let proposal = run.proposalEnvelopes.last else { return }
            await transmit([.accept(Acceptance(proposal: proposal, terms: terms))], in: key, awaitingReply: true, attemptLimit: silenceLimit, backsOff: true)
        case .confirm:
            guard run.role == .hub, let terms = run.terms else { return }
            _ = await send(.accept(Acceptance(proposal: run.proposalEnvelopes.last ?? MessageID(), terms: terms)), in: key)
            confirmationSent(run.request, to: key.peer)
        }
    }
}
