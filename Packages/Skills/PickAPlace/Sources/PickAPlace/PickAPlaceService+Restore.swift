import Foundation
import StarlingCore

// After a restart (ADR 0011, amendment 10; ADR 0230). The store keeps each
// interaction's state and current proposal; the service keeps candidates,
// lists, and replies in memory only. So:
// - Anything with a stored proposal resumes from it. The organizer sends the
//   proposal again; a friend who already said yes says it again; the
//   revision continues from the stored one.
// - A friend's request that is still waiting on its list resumes as is: the
//   organizer asks again, and the phone judges the candidates again.
// - An organizer still collecting lists cannot resume (its candidates and
//   friends' lists are gone), so it is reported as failed.
// - Anything else, or a skill on another major version, is reported failed.
// - Planned and ended interactions (the coordinator passes those that ended
//   in the last 24 hours, ADR 0011 amendment 15) leave a marker, so a late
//   query for one is ignored instead of opening it again and sending the
//   owner's list without a tap. A planned organizer is rebuilt as settled,
//   so it can still repeat its confirmation.
// Drafting needs nothing.

extension PickAPlaceService {
    public func restore(_ interactions: [Interaction]) async {
        // The hourly limit per friend survives the restart.
        await loadAdmissions()
        // Yeses taken back before the restart keep going until acknowledged.
        for withdrawal in (try? await ledger.pendingWithdrawals()) ?? [] where pendingWithdrawals[withdrawal.conversation] == nil {
            retryWithdrawal(withdrawal)
        }
        for interaction in interactions where interaction.skill.id == descriptor.id {
            switch interaction.state {
            case .drafting: continue
            case .planned, .done, .ended:
                markEnded(interaction.conversation)
                if interaction.role == .initiator, interaction.state == .planned { resumeSettled(interaction) }
                continue
            default: break
            }
            let conversation = interaction.conversation
            let isNew = conversationOf[interaction.id] == nil && organized[conversation] == nil && invites[conversation] == nil
            var resumed = false
            if isNew, interaction.skill.version.isCompatible(with: descriptor.ref.version) {
                resumed = interaction.role == .initiator ? await resumeOrganizer(interaction) : await resumeInvite(interaction)
            }
            if !resumed { emit(interaction.id, .failed) }
        }
    }

    /// A settled organizer that can repeat its confirmation, from the stored
    /// proposal and the attendees it produced.
    private func resumeSettled(_ interaction: Interaction) {
        let conversation = interaction.conversation
        guard organized[conversation] == nil, let proposal = interaction.proposal, let (place, roster) = Self.parts(of: proposal),
              roster.first == localPeer,
              let attendees = interaction.artifacts.lazy.compactMap({ if case .attendees(let people) = $0 { people.peers } else { nil } }).first
        else { return }
        var values = proposal.terms.values
        values[.people] = .peers(attendees)
        var organizer = Organizer(
            id: interaction.id, conversation: conversation, chainedFrom: interaction.chain?.parentConversation,
            friends: Array(roster.dropFirst()), ranking: [place], base: proposal.plan, time: nil, activity: nil
        )
        organizer.phase = .settled
        organizer.proposal = proposal
        organizer.ownerAccepted = true
        organizer.accepted = Set(attendees.filter { $0 != localPeer })
        organizer.finalTerms = try? Terms(values)
        organized[conversation] = organizer
        conversationOf[interaction.id] = conversation
        rememberOrganizer(conversation)
    }

    /// The live step under any open consent sheet. The sheet itself did not
    /// survive the restart; the coordinator settles it.
    private static func step(of state: InteractionState) -> InteractionState {
        if case .awaitingConsent(let resume) = state { return resume.state }
        return state
    }

    /// The proposed place and roster, if the stored proposal is one this
    /// service could have made.
    private static func parts(of proposal: SkillProposal) -> (place: PlaceChoice, roster: [PeerID])? {
        guard case .places(let places)? = proposal.terms[.place], places.count == 1, let place = places.first,
              case .peers(let roster)? = proposal.terms[.people], roster.count >= 2, roster == proposal.participants
        else { return nil }
        return (place, roster)
    }

    private func resumeOrganizer(_ interaction: Interaction) async -> Bool {
        let step = Self.step(of: interaction.state)
        guard step == .proposed || step == .confirmed, let proposal = interaction.proposal,
              let (place, roster) = Self.parts(of: proposal), roster.first == localPeer
        else { return false }
        let time: TimeSlot? = if case .slots(let slots)? = proposal.terms[.time] { slots.first } else { nil }
        let activity: Keyword? = if case .keywords(let words)? = proposal.terms[.activity] { words.first } else { nil }
        let conversation = interaction.conversation
        var organizer = Organizer(
            id: interaction.id, conversation: conversation, chainedFrom: interaction.chain?.parentConversation,
            friends: Array(roster.dropFirst()), ranking: [place], base: proposal.plan, time: time, activity: activity
        )
        organizer.phase = .proposing
        organizer.proposal = proposal
        organizer.ownerAccepted = step == .confirmed
        conversationOf[interaction.id] = conversation
        organized[conversation] = organizer
        // The original deadlines, from the ledger (re-review of PR #55,
        // finding 2). A request past its expiry or its confirm deadline, or
        // whose deadlines cannot be read, ends before anything is sent
        // again: who said yes in time did not survive the restart.
        let now = clock.now()
        guard let deadlines = try? await ledger.deadlines(for: conversation), let confirmDeadline = deadlines.confirmDeadline,
              now < deadlines.expiresAt, now < confirmDeadline
        else {
            endOrganizer(conversation, event: .expired, reason: .expired)
            return true
        }
        organized[conversation]?.confirmDeadline = confirmDeadline
        organized[conversation]?.expiresAt = deadlines.expiresAt
        startProposing(conversation)
        spawnExpiry(conversation, at: deadlines.expiresAt)
        return true
    }

    private func resumeInvite(_ interaction: Interaction) async -> Bool {
        let conversation = interaction.conversation
        switch Self.step(of: interaction.state) {
        case .negotiating:
            // The coordinator recorded the friend who asked.
            guard let organizer = interaction.participants.first, organizer != localPeer else { return false }
            // The candidates already answered, from the ledger, so only that
            // set is answered again. With none recorded, the list never
            // left, and the organizer's next query sets them. An unreadable
            // ledger leaves the request unable to answer at all.
            guard let answered = try? await ledger.answeredCandidates(in: conversation) else { return false }
            var invite = Invite(id: interaction.id, conversation: conversation, organizer: organizer, chainedFrom: interaction.friendChainHint,
                                candidates: Array(answered))
            invite.announced = true
            invite.revision = interaction.proposalRevision ?? 0
            invites[conversation] = invite
            conversationOf[interaction.id] = conversation
            spawnInviteDeadline(conversation)
            return true
        case .proposed, .confirmed:
            guard let proposal = interaction.proposal, let (place, roster) = Self.parts(of: proposal),
                  let organizer = roster.first, organizer != localPeer, roster.contains(localPeer),
                  interaction.participants.first.map({ $0 == organizer }) ?? true
            else { return false }
            var invite = Invite(id: interaction.id, conversation: conversation, organizer: organizer, chainedFrom: interaction.friendChainHint,
                                candidates: [place])
            invite.announced = true
            // This phone already found the proposed place acceptable.
            invite.acceptable = [place]
            invite.revision = proposal.revision
            invite.proposal = proposal
            invite.accepted = Self.step(of: interaction.state) == .confirmed
            invites[conversation] = invite
            conversationOf[interaction.id] = conversation
            spawnInviteDeadline(conversation)
            if invite.accepted {
                spawnAcceptance(conversation)
                spawnWaitForConfirmation(conversation)
            }
            return true
        default:
            return false
        }
    }
}
