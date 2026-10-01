import Foundation
import StarlingAvailability
import StarlingCore

// The answering side: say which offered times work, then confirm. A
// friend's query creates at most an invitee interaction. It never starts a
// skill, asks for a permission, or skips Consent (ARCHITECTURE rule 8).

extension FindATimeService {
    func receiveQuery(_ envelope: Envelope, _ query: Query) {
        let id = envelope.conversation
        guard initiating[id] == nil else { return ignore("query in our own conversation") }
        if var value = invited[id] {
            // A retry: the starter may have missed our answer.
            guard envelope.sender == value.asker else { return ignore("query from a second sender") }
            guard case .slots(let slots) = query.candidates, Set(slots) == Set(value.candidates) else { return ignore("changed query") }
            value.lastQuery = envelope.id
            invited[id] = value
            if let answered = value.answered, value.phase == .answered { sendAnswer(id, answered) }
            return
        }
        if finished[id] != nil { return replyNoPlanAgain(id, to: envelope) }

        let now = now()
        guard let candidates = QueryCheck.candidates(of: query, now: now, configuration: configuration) else {
            return ignore("query out of bounds")
        }
        // Plans already made stay until their time passes; they are not open requests.
        let open = invited.values.filter { $0.phase != .planned }
        guard open.count < configuration.maxOpenInvitations,
              open.filter({ $0.asker == envelope.sender }).count < configuration.maxOpenInvitationsPerFriend
        else { return ignore("too many open requests") }
        guard let skill = envelope.skill else { return }

        let value = Invited(
            interaction: Interaction(
                conversation: id, skill: skill, role: .invitee, participants: [envelope.sender], createdAt: Timestamp(now)
            ),
            asker: envelope.sender,
            chainedFrom: envelope.chainedFrom,
            expiresAt: Timestamp(now.addingTimeInterval(configuration.inviteeLifetime.timeInterval)),
            candidates: candidates,
            lastQuery: envelope.id,
            phase: .resolving
        )
        invited[id] = value
        announceIncoming(value)
        register(id, interaction: value.interaction.id)
        checkpoint(id)
        resolveInvitation(id)
    }

    /// Reads availability for the offered times: the calendar or stated
    /// intent if they know, otherwise the owner gets one question.
    func resolveInvitation(_ id: ConversationID) {
        guard let candidates = invited[id]?.candidates else { return }
        let availability = availability
        spawn(for: id) {
            let resolution = await availability.resolve(candidates)
            await self.invitationResolved(id, resolution)
        }
    }

    private func invitationResolved(_ id: ConversationID, _ resolution: CandidateResolution) {
        guard var value = invited[id], value.phase == .resolving else { return }
        switch resolution {
        case .known(let acceptable, _):
            // The owner's calendar or stated intent answered without asking.
            guard !acceptable.isEmpty else { return inviteeEndWithoutPlan(id, .noAgreement, tellAsker: true) }
            answer(id, with: acceptable)
        case .askOwner:
            let question = SkillQuestion(
                revision: value.interaction.questionWatermark + 1, issue: .time,
                candidates: .slots(value.candidates), asker: value.asker
            )
            value.phase = .askingOwner
            emit(.ownerNeeded(question), to: &value.interaction)
            invited[id] = value
            checkpoint(id)
        }
    }

    func inviteeAnswer(_ id: ConversationID, _ answer: OwnerAnswer) throws {
        guard var value = invited[id] else { throw FindATimeError.unknownInteraction }
        switch (value.phase, answer) {
        case (.askingOwner, .reply(let revision, let reply)):
            let picked = try checkedReply(reply, revision: revision, interaction: value.interaction)
            emit(.ownerAnswered(question: revision), to: &value.interaction)
            invited[id] = value
            guard !picked.isEmpty else { return inviteeEndWithoutPlan(id, .noAgreement, tellAsker: true) }
            self.answer(id, with: picked)

        case (.askingOwner, .pass):
            // A pass looks the same to the starter as having no time free:
            // "If you pass, they just won't see it."
            emit(.ownerPassed, to: &value.interaction)
            invited[id] = value
            sendNoPlan(about: value.lastQuery, to: [value.asker], in: id, chainedFrom: value.chainedFrom)
            finish(id)

        case (.proposed, .accept(let revision)):
            guard let offer = value.offer, offer.revision == revision, value.interaction.proposalRevision == revision else {
                throw FindATimeError.staleProposal(current: value.interaction.proposalRevision)
            }
            emit(.ownerAccepted(revision: revision), to: &value.interaction)
            value.phase = .accepted
            invited[id] = value
            resetAttempts(id)
            checkpoint(id)
            inviteeResendAcceptance(id)

        case (.proposed, .pass):
            emit(.ownerPassed, to: &value.interaction)
            invited[id] = value
            sendNoPlan(.declinedByOwner, about: value.offer?.latest ?? value.lastQuery, to: [value.asker], in: id, chainedFrom: value.chainedFrom)
            finish(id)

        case (.accepted, .accept(let revision)) where value.offer?.revision == revision:
            // Tapped twice: already accepted.
            return

        default:
            throw mismatch(answer, value.interaction)
        }
    }

    func inviteeWithdraw(_ id: ConversationID) {
        guard var value = invited[id] else { return }
        emit(.withdrawn, to: &value.interaction)
        invited[id] = value
        if value.phase != .planned { sendNoPlan(about: value.lastQuery, to: [value.asker], in: id, chainedFrom: value.chainedFrom) }
        finish(id)
    }

    private func answer(_ id: ConversationID, with slots: [TimeSlot]) {
        guard var value = invited[id] else { return }
        value.answered = slots
        value.phase = .answered
        invited[id] = value
        checkpoint(id)
        sendAnswer(id, slots)
    }

    private func sendAnswer(_ id: ConversationID, _ slots: [TimeSlot]) {
        guard let value = invited[id],
              let answer = try? Answer(query: value.lastQuery, issue: .time, status: .answered, acceptable: .slots(slots))
        else { return }
        let asker = value.asker
        let chainedFrom = value.chainedFrom
        spawn(for: id) {
            let outcome = await self.send(.answer(answer), to: asker, conversation: id, chainedFrom: chainedFrom)
            await self.answerSent(id, outcome)
        }
    }

    private func answerSent(_ id: ConversationID, _ outcome: SendOutcome) {
        guard var value = invited[id], value.phase == .answered else { return }
        switch outcome {
        case .sent, .failed:
            // A lost answer is recovered when the starter retries its query.
            return
        case .declined:
            // The owner chose not to share even the shared times: a pass.
            emitOwnerDeclinedConsent(value.interaction.id)
            sendNoPlan(about: value.lastQuery, to: [value.asker], in: id, chainedFrom: value.chainedFrom)
            finish(id)
        case .denied:
            if !emit(.blockedByPrivacy, to: &value.interaction) { emit(.failed, to: &value.interaction) }
            invited[id] = value
            sendNoPlan(about: value.lastQuery, to: [value.asker], in: id, chainedFrom: value.chainedFrom)
            finish(id)
        }
    }

    func receiveProposal(_ envelope: Envelope, _ proposal: Proposal) {
        let id = envelope.conversation
        guard initiating[id] == nil else { return ignore("proposal in our own conversation") }
        guard var value = invited[id] else {
            if finished[id] != nil { replyNoPlanAgain(id, to: envelope) }
            return ignore("proposal without a request")
        }
        guard envelope.sender == value.asker else { return ignore("proposal from a second sender") }
        guard [.answered, .proposed, .accepted].contains(value.phase), let answered = value.answered else {
            return ignore("proposal out of turn")
        }
        guard let terms = OfferTerms(proposal.terms, asker: value.asker, local: localPeer) else { return ignore("proposal terms") }
        // Only a time this phone said works: a starter cannot propose a time
        // the owner never agreed to share.
        guard answered.contains(terms.slot) else { return ignore("proposal outside our answer") }

        if var offer = value.offer, offer.terms == proposal.terms, offer.round == proposal.round {
            // A retry of the proposal we have.
            offer.ids.insert(envelope.id)
            offer.latest = envelope.id
            value.offer = offer
            invited[id] = value
            checkpoint(id)
            if value.phase == .accepted { inviteeResendAcceptance(id) }
            return
        }
        guard value.offer.map({ proposal.round > $0.round }) ?? true else { return ignore("older proposal") }
        guard let plan = try? terms.plan(origin: id, asker: value.asker, local: localPeer) else { return ignore("proposal plan") }

        let revision = (value.interaction.proposalRevision ?? 0) + 1
        let offer = Offer(round: proposal.round, terms: proposal.terms, ids: [envelope.id], latest: envelope.id, revision: revision, plan: plan)
        let card = SkillProposal(revision: revision, participants: plan.attendees.peers, terms: proposal.terms, plan: plan)
        guard emit(.proposalReady(card), to: &value.interaction) else { return }
        value.offer = offer
        value.phase = .proposed
        invited[id] = value
        checkpoint(id)
    }

    func inviteeResendAcceptance(_ id: ConversationID) {
        guard let value = invited[id], value.phase == .accepted, let offer = value.offer, countAttempt(id, value.asker) else { return }
        let acceptance = Acceptance(proposal: offer.latest, terms: offer.terms)
        let asker = value.asker
        let chainedFrom = value.chainedFrom
        spawn(for: id) {
            let outcome = await self.send(.accept(acceptance), to: asker, conversation: id, chainedFrom: chainedFrom)
            await self.acceptanceSent(id, outcome)
        }
    }

    private func acceptanceSent(_ id: ConversationID, _ outcome: SendOutcome) {
        guard var value = invited[id], value.phase == .accepted else { return }
        switch outcome {
        case .sent, .failed:
            return
        case .declined:
            emitOwnerDeclinedConsent(value.interaction.id)
            sendNoPlan(.declinedByOwner, about: value.offer?.latest ?? value.lastQuery, to: [value.asker], in: id, chainedFrom: value.chainedFrom)
            finish(id)
        case .denied:
            if !emit(.blockedByPrivacy, to: &value.interaction) { emit(.failed, to: &value.interaction) }
            invited[id] = value
            sendNoPlan(about: value.lastQuery, to: [value.asker], in: id, chainedFrom: value.chainedFrom)
            finish(id)
        }
    }

    /// The starter's confirmation: everyone said "That works".
    func receiveConfirmation(_ envelope: Envelope, _ acceptance: Acceptance) {
        let id = envelope.conversation
        guard var value = invited[id], envelope.sender == value.asker else { return ignore("confirmation from a stranger") }
        guard value.phase == .accepted, let offer = value.offer else {
            return value.phase == .planned ? () : ignore("confirmation out of turn")
        }
        guard acceptance.terms == offer.terms, offer.ids.contains(acceptance.proposal) else { return ignore("confirmation of other terms") }
        guard emit(.everyoneConfirmed(revision: offer.revision), to: &value.interaction) else { return }
        value.phase = .planned
        invited[id] = value
        if let time = offer.plan.time { produce(.timeSlot(time), for: value.interaction.id) }
        produce(.plan(offer.plan), for: value.interaction.id)
        checkpoint(id)
    }

    func receiveInviteeRejection(_ envelope: Envelope) {
        let id = envelope.conversation
        guard let value = invited[id], envelope.sender == value.asker else { return ignore("rejection from a stranger") }
        guard value.phase != .planned else { return ignore("rejection after the plan") }
        // While the owner's question is open, "no plan" means the question
        // no longer matters; the lifecycle calls that expired.
        inviteeEndWithoutPlan(id, value.phase == .askingOwner ? .expired : .noAgreement, tellAsker: false)
    }

    func inviteeEndWithoutPlan(_ id: ConversationID, _ event: InteractionEvent, tellAsker: Bool) {
        guard var value = invited[id] else { return }
        if !emit(event, to: &value.interaction) { emit(.failed, to: &value.interaction) }
        invited[id] = value
        if tellAsker { sendNoPlan(about: value.lastQuery, to: [value.asker], in: id, chainedFrom: value.chainedFrom) }
        finish(id)
    }

    /// A late query or proposal for a conversation that ended here gets the
    /// same "no plan", a bounded number of times, and never a new card.
    private func replyNoPlanAgain(_ id: ConversationID, to envelope: Envelope) {
        guard var tombstone = finished[id], tombstone.asker == envelope.sender, tombstone.replies < configuration.maxAttempts else { return }
        tombstone.replies += 1
        finished[id] = tombstone
        sendNoPlan(about: envelope.id, to: [envelope.sender], in: id, chainedFrom: envelope.chainedFrom)
    }

    func inviteeTick(_ id: ConversationID) {
        guard let value = invited[id] else { return }
        switch value.phase {
        case .planned:
            if let end = value.offer?.plan.time?.end, now() >= end {
                var ended = value
                emit(.planEnded, to: &ended.interaction)
                invited[id] = ended
                finish(id)
            }
        case _ where expired(value.expiresAt):
            inviteeEndWithoutPlan(id, .expired, tellAsker: true)
        case .accepted:
            inviteeResendAcceptance(id)
        default:
            break
        }
    }
}
