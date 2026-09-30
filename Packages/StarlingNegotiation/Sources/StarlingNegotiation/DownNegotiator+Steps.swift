import Foundation
import StarlingCore

// The protocol steps of ADR 0120. Each handler runs on the peer's own work
// queue, so steps for one friend never interleave. Other actor work can run
// at every `await`, so handlers re-read the conversation afterwards and stop
// if it has ended.

extension DownNegotiator {
    func dispatch(_ envelope: Envelope, in id: ConversationID) async {
        switch envelope.body {
        case .psi(let frame): await handlePSI(frame, in: id)
        case .query(let query): await handleQuery(query, envelope: envelope, in: id)
        case .answer(let answer): await handleAnswer(answer, in: id)
        case .propose(let proposal): await handleOffer(proposal, isCounter: false, envelope: envelope, in: id)
        case .counter(let proposal): await handleOffer(proposal, isCounter: true, envelope: envelope, in: id)
        case .accept(let acceptance): await handleAccept(acceptance, in: id)
        case .reject: end(id, .rejected)
        case .hello: break
        }
    }

    // MARK: - Mutual interest (PSI)

    func handlePSI(_ frame: PSIFrame, in id: ConversationID) async {
        guard let conversation = conversations[id], conversation.phase == .psi,
              frame.session == conversation.psiSessionID, frame.step == conversation.nextInboundPSIStep,
              frame.step < UInt8.max - 1
        else { return }

        let step: PSIStep
        do {
            step = try await conversation.psi.handle(frame.payload)
        } catch {
            // Oversized or malformed peer set: stop without a word.
            end(id, .failed)
            return
        }
        guard var current = conversations[id], current.phase == .psi else { return }
        let signature = DownSignature.psi(step: frame.step, payload: frame.payload)

        switch step {
        case .send(let payload):
            guard let reply = try? PSIFrame(session: current.psiSessionID, step: frame.step + 1, payload: payload) else {
                end(id, .failed)
                return
            }
            current.replies[signature] = .psi(reply)
            current.nextInboundPSIStep = frame.step + 2
            conversations[id] = current
            await transmit([.psi(reply)], in: id, awaitingReply: true)

        case .finish(let payload, let result):
            if let payload {
                guard let reply = try? PSIFrame(session: current.psiSessionID, step: frame.step + 1, payload: payload) else {
                    end(id, .failed)
                    return
                }
                current.replies[signature] = .psi(reply)
                conversations[id] = current
                guard await send(.psi(reply), to: current.peer, in: id, profile: current.profile) != .ended else { return }
            }
            await finishPSI(result, in: id)
        }
    }

    private func finishPSI(_ result: PSIResult?, in id: ConversationID) async {
        guard var conversation = conversations[id] else { return }
        switch result {
        case .intersection(let shared)?:
            let slots = conversation.profile.tokens.slots(in: shared)
            guard !slots.isEmpty else { return end(id, .noOverlap) }
            conversation.overlap = slots
        case .cardinality(let count)?:
            guard count > 0 else { return end(id, .noOverlap) }
        case nil:
            break
        }

        if conversation.role == .initiator {
            // The initiator proposes a time, so it must know the shared slots.
            guard conversation.overlap != nil else { return end(id, .failed) }
            conversations[id] = conversation
            await askDetails(in: id)
        } else {
            conversation.phase = .awaitingOffer
            conversations[id] = conversation
            await transmit([], in: id, awaitingReply: false)
        }
    }

    // MARK: - Details, only after overlap

    private func askDetails(in id: ConversationID) async {
        guard var conversation = conversations[id] else { return }
        var bodies: [MessageBody] = []
        let liked = Array(conversation.profile.liked.prefix(ProtocolLimits.maxKeywordsPerValue))
        if !liked.isEmpty, let query = try? Query(issue: .activity, candidates: .keywords(liked)) {
            bodies.append(.query(query))
            conversation.pendingQueries.insert(.activity)
            conversation.askedActivity = true
        }
        if let cap = conversation.profile.budgetCap, let query = try? Query(issue: .budget, candidates: .amount(cap)) {
            bodies.append(.query(query))
            conversation.pendingQueries.insert(.budget)
        }
        guard !bodies.isEmpty else {
            conversations[id] = conversation
            return await proposeOpening(in: id)
        }
        conversation.phase = .awaitingAnswers
        conversations[id] = conversation
        await transmit(bodies, in: id, awaitingReply: true)
    }

    private func handleQuery(_ query: Query, envelope: Envelope, in id: ConversationID) async {
        guard let conversation = conversations[id], conversation.role == .responder, conversation.phase == .awaitingOffer else { return }
        let profile = conversation.profile

        let value: IssueValue?
        switch (query.issue, query.candidates) {
        case (.activity, .keywords(let candidates)):
            // Before the model: it never sees a keyword the owner avoids.
            let usable = candidates.filter { !profile.avoided.contains($0) }
            var matches: [KeywordMatch] = []
            if profile.needsModelToMatch, !usable.isEmpty {
                noteModelCall()
                matches = (try? await model.match(wanted: profile.liked, offered: usable).value) ?? []
                guard conversations[id] != nil else { return }
            }
            // After the model: code decides what counts.
            value = .keywords(profile.acceptableActivities(candidates: candidates, matches: matches))
        case (.budget, .amount(let amount)):
            value = profile.budgetAnswer(for: amount).map(IssueValue.amount)
        default:
            value = nil
        }

        let reply = DownReply.answer(issue: query.issue, value: value)
        guard var current = conversations[id], let body = try? reply.body(answering: envelope) else { return }
        current.replies[.query(query)] = reply
        conversations[id] = current
        await transmit([body], in: id, awaitingReply: false)
    }

    private func handleAnswer(_ answer: Answer, in id: ConversationID) async {
        guard var conversation = conversations[id], conversation.phase == .awaitingAnswers,
              let issue = conversation.queries[answer.query], answer.issue == issue, conversation.pendingQueries.contains(issue)
        else { return }
        switch (issue, answer.acceptable) {
        case (.activity, .keywords(let keywords)?): conversation.activityAnswer = keywords
        case (.activity, _): conversation.activityAnswer = []
        case (.budget, .amount(let amount)?): conversation.budgetAnswer = amount
        default: break
        }
        conversation.pendingQueries.remove(issue)
        conversations[id] = conversation
        if conversation.pendingQueries.isEmpty { await proposeOpening(in: id) }
    }

    // MARK: - Offers

    private func proposeOpening(in id: ConversationID) async {
        guard let conversation = conversations[id], let overlap = conversation.overlap else { return }
        guard let plan = conversation.profile.openingPlan(
            overlap: overlap,
            activities: conversation.askedActivity ? (conversation.activityAnswer ?? []) : nil,
            budget: conversation.budgetAnswer,
            maxMinutes: configuration.maxPlanMinutes
        ) else { return end(id, .noOverlap) }
        await makeOffer(plan, round: 0, inReplyTo: nil, in: id)
    }

    private func makeOffer(_ plan: Terms, round: UInt16, inReplyTo: MessageID?, in id: ConversationID) async {
        guard var conversation = conversations[id], let proposal = try? Proposal(round: round, terms: plan, inReplyTo: inReplyTo) else { return }
        let kind: MessageBody.Kind = round == 0 ? .propose : .counter
        conversation.myOffer = DownConversation.Offer(round: round, terms: plan, envelopes: [])
        conversation.history.append(NegotiationRound(actor: .me, kind: kind, terms: plan))
        conversation.phase = .awaitingReply
        conversations[id] = conversation
        await transmit([kind == .propose ? .propose(proposal) : .counter(proposal)], in: id, awaitingReply: true)
    }

    private func handleOffer(_ proposal: Proposal, isCounter: Bool, envelope: Envelope, in id: ConversationID) async {
        guard var conversation = conversations[id] else { return }
        switch conversation.phase {
        case .awaitingOffer:
            guard !isCounter, conversation.role == .responder, proposal.round == 0 else { return }
        case .awaitingReply:
            guard isCounter, let mine = conversation.myOffer, proposal.round == mine.round + 1 else { return }
        case .psi, .awaitingAnswers, .awaitingConfirm:
            return
        }
        conversation.theirOffer = DownConversation.Offer(round: proposal.round, terms: proposal.terms, envelopes: [envelope.id])
        conversation.myOffer = nil
        conversation.history.append(NegotiationRound(actor: .peer, kind: isCounter ? .counter : .propose, terms: proposal.terms))
        conversations[id] = conversation

        let profile = conversation.profile
        let signature = DownSignature.offer(round: proposal.round, terms: proposal.terms)
        let canCounter = proposal.round + 1 < configuration.maxRounds

        switch profile.assess(proposal.terms, overlap: conversation.overlap, canCounter: canCounter, now: clock.now()) {
        case .reject(let reason):
            await rejectOffer(reason, signature: signature, envelope: envelope, in: id)
        case .repair(let terms):
            await counterOffer(terms, round: proposal.round + 1, signature: signature, envelope: envelope, in: id)
        case .acceptable(let alternatives):
            // The model only chooses among options code already checked; any
            // other answer, or an error, means accept as offered.
            var choice: Terms?
            if !alternatives.isEmpty {
                noteModelCall()
                let context = NegotiationContext(proposal: proposal, constraints: profile.constraints, history: conversation.history, now: clock.now())
                let move = try? await model.decide(context).value
                guard conversations[id] != nil else { return }
                if case .counter(let terms)? = move, alternatives.contains(terms), profile.permits(terms) { choice = terms }
            }
            if let choice {
                await counterOffer(choice, round: proposal.round + 1, signature: signature, envelope: envelope, in: id)
            } else {
                await acceptOffer(proposal.terms, signature: signature, envelope: envelope, in: id)
            }
        }
    }

    private func acceptOffer(_ plan: Terms, signature: DownSignature, envelope: Envelope, in id: ConversationID) async {
        guard var conversation = conversations[id] else { return }
        let accepted = conversation.profile.accepting(plan)
        conversation.replies[signature] = .accept(accepted)
        conversation.phase = .awaitingConfirm
        conversations[id] = conversation
        await transmit([.accept(Acceptance(proposal: envelope.id, terms: accepted))], in: id, awaitingReply: true)
    }

    private func counterOffer(_ plan: Terms, round: UInt16, signature: DownSignature, envelope: Envelope, in id: ConversationID) async {
        guard var conversation = conversations[id] else { return }
        conversation.replies[signature] = .counter(round: round, terms: plan)
        conversations[id] = conversation
        await makeOffer(plan, round: round, inReplyTo: envelope.id, in: id)
    }

    private func rejectOffer(_ reason: Rejection.Reason, signature: DownSignature, envelope: Envelope, in id: ConversationID) async {
        guard var conversation = conversations[id] else { return }
        conversation.replies[signature] = .reject(reason)
        conversations[id] = conversation
        guard await send(.reject(Rejection(proposal: envelope.id, reason: reason)), to: conversation.peer, in: id, profile: conversation.profile) != .ended else { return }
        end(id, .rejected)
    }

    // MARK: - Match before notify

    /// Two acceptances make a match. The peer that did not make the final
    /// offer accepts first; the offerer checks it, confirms with its own
    /// accept, and only then notifies. The first peer notifies when the
    /// confirmation arrives. Neither side notifies without the other's
    /// accept of the identical plan, and each level travels only inside an
    /// accept (ADR 0120).
    private func handleAccept(_ acceptance: Acceptance, in id: ConversationID) async {
        guard var conversation = conversations[id], let (plan, peerLevel) = DownProfile.split(acceptance.terms) else { return }
        let profile = conversation.profile

        switch conversation.phase {
        case .awaitingReply:
            guard let mine = conversation.myOffer, mine.envelopes.contains(acceptance.proposal),
                  plan == mine.terms, profile.permits(plan), profile.hasNotStarted(plan, now: clock.now())
            else { return }
            let confirmation = profile.accepting(plan)
            // Notify only once the confirmation is really on its way. If the
            // link lost it, the peer's retry comes back through here.
            guard await send(.accept(Acceptance(proposal: acceptance.proposal, terms: confirmation)), to: conversation.peer, in: id, profile: profile) == .sent,
                  var current = conversations[id]
            else { return }
            current.replies[.accept(acceptance.terms)] = .confirm(confirmation)
            conversations[id] = current
            notifyMatch(with: current.peer, plan: plan, peerLevel: peerLevel, ownLevel: profile.level)
            end(id, .matched)

        case .awaitingConfirm:
            guard let theirs = conversation.theirOffer, theirs.envelopes.contains(acceptance.proposal),
                  plan == theirs.terms, profile.permits(plan), profile.hasNotStarted(plan, now: clock.now())
            else { return }
            conversation.outstanding = []
            conversations[id] = conversation
            notifyMatch(with: conversation.peer, plan: plan, peerLevel: peerLevel, ownLevel: profile.level)
            end(id, .matched)

        case .psi, .awaitingAnswers, .awaitingOffer:
            return
        }
    }
}
