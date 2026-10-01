import Foundation
import StarlingAvailability
import StarlingCore

// The starter's side: offer times, collect answers, propose, confirm.

extension FindATimeService {
    func startInitiating(_ request: SkillRequest) throws {
        let skill = request.intent.skill
        guard skill.id == FindATimeSkill.ref.id, skill.version.isCompatible(with: FindATimeSkill.ref.version) else {
            throw FindATimeError.wrongSkill
        }
        let id = request.conversation
        guard conversationOf[request.interaction] == nil, initiating[id] == nil, invited[id] == nil, finished[id] == nil else {
            throw FindATimeError.alreadyStarted
        }
        let now = now()
        let grid = try SearchRange.candidates(rules: request.intent.rules, now: now, timeZone: timeZone, configuration: configuration)

        var friends: [PeerID] = []
        for peer in request.participants where peer != localPeer && !friends.contains(peer) && friends.count < ProtocolLimits.maxAttendees - 1 {
            friends.append(peer)
        }
        var value = Initiating(
            interaction: Interaction(
                id: request.interaction, conversation: id, skill: FindATimeSkill.ref, role: .initiator,
                participants: friends, createdAt: Timestamp(now)
            ),
            chainedFrom: request.chainedFrom,
            expiresAt: request.intent.expiresAt,
            activity: SearchRange.activity(in: request.intent.rules),
            invitees: friends,
            phase: .resolving
        )
        guard !friends.isEmpty else {
            // Nobody to ask: the app resolved no friend who runs the skill.
            emit(.unsupported, to: &value.interaction)
            return
        }
        emit(.started, to: &value.interaction)
        initiating[id] = value
        register(id, interaction: request.interaction)
        checkpoint(id)

        let availability = availability
        spawn {
            let resolution = await availability.resolve(grid)
            await self.ownTimesResolved(id, resolution, grid: grid)
        }
    }

    private func ownTimesResolved(_ id: ConversationID, _ resolution: CandidateResolution, grid: [TimeSlot]) {
        guard var value = initiating[id], value.phase == .resolving else { return }
        switch resolution {
        case .known(let acceptable, _):
            guard !acceptable.isEmpty else {
                // Busy for the whole range: nothing to offer.
                return endWithoutPlan(id, .noAgreement)
            }
            value.candidates = CandidateGrid.thinned(acceptable, to: configuration.maxCandidates)
            initiating[id] = value
            beginCollecting(id)
        case .askOwner:
            value.candidates = CandidateGrid.thinned(grid, to: configuration.maxCandidates)
            let question = SkillQuestion(
                revision: value.interaction.questionWatermark + 1, issue: .time,
                candidates: .slots(value.candidates), asker: nil
            )
            value.phase = .askingOwner
            emit(.ownerNeeded(question), to: &value.interaction)
            initiating[id] = value
            checkpoint(id)
        }
    }

    func initiatorAnswer(_ id: ConversationID, _ answer: OwnerAnswer) throws {
        guard var value = initiating[id] else { throw FindATimeError.unknownInteraction }
        switch (value.phase, answer) {
        case (.askingOwner, .reply(let revision, let reply)):
            let picked = try checkedReply(reply, revision: revision, interaction: value.interaction)
            emit(.ownerAnswered(question: revision), to: &value.interaction)
            initiating[id] = value
            guard !picked.isEmpty else { return endWithoutPlan(id, .noAgreement) }
            initiating[id]?.candidates = picked
            beginCollecting(id)

        case (.askingOwner, .pass):
            emit(.ownerPassed, to: &value.interaction)
            initiating[id] = value
            finish(id)

        case (.proposing, .accept(let revision)):
            guard let draft = value.draft, revision == draft.revision, value.interaction.proposalRevision == revision else {
                throw FindATimeError.staleProposal(current: value.interaction.proposalRevision)
            }
            guard !value.ownerAccepted else { return }
            emit(.ownerAccepted(revision: revision), to: &value.interaction)
            value.ownerAccepted = true
            initiating[id] = value
            checkpoint(id)
            confirmIfEveryoneAccepted(id)

        case (.proposing, .pass):
            emit(.ownerPassed, to: &value.interaction)
            initiating[id] = value
            tellEveryoneNoPlan(id)
            finish(id)

        default:
            throw mismatch(answer, value.interaction)
        }
    }

    func initiatorWithdraw(_ id: ConversationID) {
        guard var value = initiating[id] else { return }
        emit(.withdrawn, to: &value.interaction)
        initiating[id] = value
        // After a plan is made, withdrawing only ends it on this phone.
        if value.phase != .planned { tellEveryoneNoPlan(id) }
        finish(id)
    }

    // MARK: Collecting answers

    private func beginCollecting(_ id: ConversationID) {
        guard var value = initiating[id] else { return }
        value.phase = .collecting
        value.answerDeadline = deadline(after: configuration.answerWait, capped: value.expiresAt)
        initiating[id] = value
        resetAttempts(id)
        checkpoint(id)
        sendQueries(id, to: value.invitees)
    }

    private func sendQueries(_ id: ConversationID, to peers: [PeerID]) {
        guard let value = initiating[id], value.phase == .collecting,
              let query = try? Query(issue: .time, candidates: .slots(value.candidates))
        else { return }
        let targets = peers.filter { value.answers[$0] == nil && countAttempt(id, $0) }
        guard !targets.isEmpty else { return }
        let chainedFrom = value.chainedFrom
        spawn {
            for peer in targets {
                let outcome = await self.send(.query(query), to: peer, conversation: id, chainedFrom: chainedFrom)
                await self.querySent(id, to: peer, outcome)
            }
        }
    }

    private func querySent(_ id: ConversationID, to peer: PeerID, _ outcome: SendOutcome) {
        guard var value = initiating[id], value.phase == .collecting, value.answers[peer] == nil else { return }
        switch outcome {
        case .sent, .failed:
            return
        case .declined, .denied:
            // The owner chose not to ask this friend, or the policy refused:
            // the friend is left out, as if they had no time.
            value.answers[peer] = []
            value.excluded.insert(peer)
            initiating[id] = value
            checkpoint(id)
            if value.excluded.count == value.invitees.count {
                // Nobody was asked. A declined sheet is the owner passing;
                // a refusal is privacy.
                if case .declined = outcome {
                    emitOwnerDeclinedConsent(value.interaction.id)
                } else if !emit(.blockedByPrivacy, to: &value.interaction) {
                    emit(.failed, to: &value.interaction)
                }
                return finish(id)
            }
            decideIfEveryoneAnswered(id)
        }
    }

    func receiveAnswer(_ envelope: Envelope, _ answer: Answer) {
        let id = envelope.conversation
        guard var value = initiating[id], value.phase == .collecting, value.invitees.contains(envelope.sender) else {
            return ignore("answer out of turn")
        }
        guard value.answers[envelope.sender] == nil else { return ignore("duplicate answer") }
        guard answer.issue == .time else { return ignore("answer for another issue") }
        switch answer.status {
        case .answered:
            guard case .slots(let slots)? = answer.acceptable else { return ignore("answer is not times") }
            let offered = Set(value.candidates)
            // Only times we offered count; an answer that adds any is refused
            // whole, so a friend cannot steer the plan to a time we never offered.
            guard slots.allSatisfy(offered.contains) else { return ignore("answer outside the offer") }
            value.answers[envelope.sender] = Array(Set(slots)).sorted()
        case .declined:
            value.answers[envelope.sender] = []
        case .pendingOwner:
            return
        }
        initiating[id] = value
        checkpoint(id)
        decideIfEveryoneAnswered(id)
    }

    func receiveInitiatorRejection(_ envelope: Envelope) {
        let id = envelope.conversation
        guard var value = initiating[id], value.invitees.contains(envelope.sender) else { return ignore("rejection from a stranger") }
        switch value.phase {
        case .collecting where value.answers[envelope.sender] == nil:
            value.answers[envelope.sender] = []
            initiating[id] = value
            checkpoint(id)
            decideIfEveryoneAnswered(id)
        case .proposing:
            guard value.draft?.members.contains(envelope.sender) == true else { return ignore("rejection from a non-member") }
            memberPassed(id, envelope.sender)
        default:
            ignore("rejection out of turn")
        }
    }

    private func decideIfEveryoneAnswered(_ id: ConversationID) {
        guard let value = initiating[id], value.phase == .collecting, value.waitingOn.isEmpty else { return }
        decide(id)
    }

    /// The time the most friends can make, earliest first; friends who
    /// cannot make it are told "no plan".
    private func decide(_ id: ConversationID) {
        guard let value = initiating[id], value.phase == .collecting else { return }
        let free = { (peer: PeerID, slot: TimeSlot) in value.answers[peer]?.contains(slot) == true }
        let counts = value.candidates.map { slot in value.invitees.filter { free($0, slot) }.count }
        guard let best = counts.max(), best > 0, let index = counts.firstIndex(of: best) else {
            return endWithoutPlan(id, .noAgreement)
        }
        let slot = value.candidates[index]
        let members = value.invitees.filter { free($0, slot) }
        let others = value.invitees.filter { !members.contains($0) && !value.excluded.contains($0) }
        sendNoPlan(about: MessageID(), to: others, in: id, chainedFrom: value.chainedFrom)
        propose(id, slot: slot, members: members)
    }

    // MARK: Proposing

    private func propose(_ id: ConversationID, slot: TimeSlot, members: [PeerID]) {
        guard var value = initiating[id] else { return }
        let revision = max(value.draft?.revision ?? 0, value.interaction.proposalRevision ?? 0) + 1
        let roster = ([localPeer] + members).sorted()
        guard revision <= configuration.maxRevisions,
              let terms = try? OfferTerms.terms(slot: slot, activity: value.activity, roster: roster),
              let plan = try? Plan(origin: id, attendees: Attendees(roster), activity: value.activity, time: slot)
        else { return endWithoutPlan(id, .noAgreement) }
        value.draft = Draft(revision: revision, slot: slot, members: members, terms: terms, plan: plan)
        value.phase = .proposing
        value.proposalIDs = [:]
        value.accepted = [:]
        value.ownerAccepted = false
        value.confirmDeadline = deadline(after: configuration.confirmWait, capped: value.expiresAt)
        initiating[id] = value
        resetAttempts(id)
        checkpoint(id)
        sendProposals(id, revision: revision, to: members, announce: true)
    }

    /// Sends a saved proposal again after a restart, showing its card.
    func proposeAgain(_ id: ConversationID, _ draft: Draft) {
        guard var value = initiating[id] else { return }
        value.draft = draft
        value.phase = .proposing
        initiating[id] = value
        resetAttempts(id)
        sendProposals(id, revision: draft.revision, to: draft.members.filter { value.accepted[$0] == nil }, announce: true)
    }

    /// Sends the current proposal. With `announce`, the proposal card goes
    /// up only after every send has passed policy and consent, so the card
    /// never appears while a consent sheet for it is still open.
    private func sendProposals(_ id: ConversationID, revision: UInt32, to peers: [PeerID], announce: Bool) {
        guard let value = initiating[id], value.phase == .proposing, let draft = value.draft, draft.revision == revision else { return }
        let targets = announce ? peers : peers.filter { countAttempt(id, $0) }
        guard !targets.isEmpty || announce else { return }
        guard let proposal = try? Proposal(round: UInt16(revision - 1), terms: draft.terms, expiresAt: value.confirmDeadline) else { return }
        if announce { for peer in targets { _ = countAttempt(id, peer) } }
        let chainedFrom = value.chainedFrom
        spawn {
            var refusal: SendOutcome?
            for peer in targets {
                let outcome = await self.send(.propose(proposal), to: peer, conversation: id, chainedFrom: chainedFrom)
                switch outcome {
                case .sent(let envelope): await self.proposalSent(id, revision: revision, to: peer, envelope.id)
                case .declined, .denied: refusal = outcome
                case .failed: continue
                }
                if refusal != nil { break }
            }
            await self.proposalsDone(id, revision: revision, announce: announce, refusal: refusal)
        }
    }

    private func proposalSent(_ id: ConversationID, revision: UInt32, to peer: PeerID, _ message: MessageID) {
        guard var value = initiating[id], value.draft?.revision == revision else { return }
        value.proposalIDs[peer, default: []].insert(message)
        initiating[id] = value
        checkpoint(id)
    }

    private func proposalsDone(_ id: ConversationID, revision: UInt32, announce: Bool, refusal: SendOutcome?) {
        guard var value = initiating[id], value.phase == .proposing, let draft = value.draft, draft.revision == revision else { return }
        switch refusal {
        case .declined?:
            emitOwnerDeclinedConsent(value.interaction.id)
            tellEveryoneNoPlan(id)
            return finish(id)
        case .denied?:
            // The roster's topic is set to Never.
            if !emit(.blockedByPrivacy, to: &value.interaction) { emit(.failed, to: &value.interaction) }
            initiating[id] = value
            tellEveryoneNoPlan(id)
            return finish(id)
        default:
            break
        }
        guard announce else { return }
        let card = SkillProposal(revision: revision, participants: draft.plan.attendees.peers, terms: draft.terms, plan: draft.plan)
        emit(.proposalReady(card), to: &value.interaction)
        initiating[id] = value
        checkpoint(id)
    }

    func receiveAcceptance(_ envelope: Envelope, _ acceptance: Acceptance) {
        let id = envelope.conversation
        let peer = envelope.sender
        guard var value = initiating[id], let draft = value.draft, draft.members.contains(peer) else {
            return ignore("acceptance from a non-member")
        }
        guard acceptance.terms == draft.terms, value.proposalIDs[peer]?.contains(acceptance.proposal) == true else {
            return ignore("acceptance of other terms")
        }
        switch value.phase {
        case .proposing:
            value.accepted[peer] = acceptance.proposal
            initiating[id] = value
            checkpoint(id)
            confirmIfEveryoneAccepted(id)
        case .planned:
            // Our confirmation was lost: send it again.
            let chainedFrom = value.chainedFrom
            spawn {
                _ = await self.send(.accept(Acceptance(proposal: acceptance.proposal, terms: draft.terms)), to: peer, conversation: id, chainedFrom: chainedFrom)
            }
        default:
            ignore("acceptance out of turn")
        }
    }

    private func memberPassed(_ id: ConversationID, _ peer: PeerID) {
        guard let value = initiating[id], let draft = value.draft else { return }
        let remaining = draft.members.filter { $0 != peer }
        guard !remaining.isEmpty else { return endWithoutPlan(id, .noAgreement, notify: false) }
        // The same time still works for everyone else; they confirm again
        // because the roster changed.
        propose(id, slot: draft.slot, members: remaining)
    }

    private func confirmIfEveryoneAccepted(_ id: ConversationID) {
        guard var value = initiating[id], value.phase == .proposing, value.ownerAccepted, let draft = value.draft,
              draft.members.allSatisfy({ value.accepted[$0] != nil })
        else { return }
        value.phase = .planned
        initiating[id] = value
        checkpoint(id)
        let ids = value.accepted
        let chainedFrom = value.chainedFrom
        spawn {
            var declined = false
            for peer in draft.members {
                guard let message = ids[peer] else { continue }
                let outcome = await self.send(.accept(Acceptance(proposal: message, terms: draft.terms)), to: peer, conversation: id, chainedFrom: chainedFrom)
                if case .declined = outcome { declined = true; break }
            }
            await self.confirmationsDone(id, revision: draft.revision, declined: declined)
        }
    }

    func confirmationsDone(_ id: ConversationID, revision: UInt32, declined: Bool) {
        guard var value = initiating[id], value.phase == .planned, let draft = value.draft, draft.revision == revision else { return }
        if declined {
            emitOwnerDeclinedConsent(value.interaction.id)
            tellEveryoneNoPlan(id)
            return finish(id)
        }
        // A friend who missed the confirmation resends its acceptance, and
        // `receiveAcceptance` answers it, so the plan stands on this phone.
        emit(.everyoneConfirmed(revision: revision), to: &value.interaction)
        initiating[id] = value
        produce(.timeSlot(draft.slot), for: value.interaction.id)
        produce(.plan(draft.plan), for: value.interaction.id)
        checkpoint(id)
    }

    // MARK: Endings and timers

    /// Ends with no plan and tells every friend still waiting.
    func endWithoutPlan(_ id: ConversationID, _ event: InteractionEvent, notify: Bool = true) {
        guard var value = initiating[id] else { return }
        if !emit(event, to: &value.interaction) { emit(.failed, to: &value.interaction) }
        initiating[id] = value
        if notify { tellEveryoneNoPlan(id) }
        finish(id)
    }

    private func tellEveryoneNoPlan(_ id: ConversationID) {
        guard let value = initiating[id] else { return }
        let peers = value.invitees.filter { !value.excluded.contains($0) }
        sendNoPlan(about: MessageID(), to: peers, in: id, chainedFrom: value.chainedFrom)
    }

    func initiatorTick(_ id: ConversationID) {
        guard let value = initiating[id] else { return }
        switch value.phase {
        case .planned:
            if let end = value.draft?.slot.end, now() >= end {
                var ended = value
                emit(.planEnded, to: &ended.interaction)
                initiating[id] = ended
                finish(id)
            }
        case _ where expired(value.expiresAt):
            endWithoutPlan(id, .expired)
        case .collecting where expired(value.answerDeadline):
            // Friends who have not answered are treated as having no time.
            decide(id)
        case .proposing where expired(value.confirmDeadline):
            endWithoutPlan(id, .expired)
        case .collecting, .proposing:
            initiatorResend(id, to: value.waitingOn)
        case .resolving, .askingOwner:
            break
        }
    }

    func initiatorResend(_ id: ConversationID, to peers: [PeerID]) {
        guard let value = initiating[id], !peers.isEmpty else { return }
        switch value.phase {
        case .collecting: sendQueries(id, to: peers)
        case .proposing: if let revision = value.draft?.revision { sendProposals(id, revision: revision, to: peers, announce: false) }
        default: break
        }
    }

    /// Why an answer does not fit: an acceptance names a proposal that is
    /// not current, a reply a question that is not pending.
    func mismatch(_ answer: OwnerAnswer, _ interaction: Interaction) -> FindATimeError {
        switch answer {
        case .accept: .staleProposal(current: interaction.proposalRevision)
        case .reply: .staleQuestion(current: interaction.pendingQuestion?.revision)
        case .pass: .notWaitingForThis
        }
    }

    /// Checks an owner's reply to the pending question: the right revision,
    /// and only times the question offered.
    func checkedReply(_ reply: IssueValue, revision: UInt32, interaction: Interaction) throws -> [TimeSlot] {
        guard let question = interaction.pendingQuestion, question.revision == revision else {
            throw FindATimeError.staleQuestion(current: interaction.pendingQuestion?.revision)
        }
        guard case .slots(let picked) = reply, case .slots(let offered) = question.candidates,
              picked.allSatisfy(Set(offered).contains)
        else { throw FindATimeError.invalidReply }
        return Array(Set(picked)).sorted()
    }
}
