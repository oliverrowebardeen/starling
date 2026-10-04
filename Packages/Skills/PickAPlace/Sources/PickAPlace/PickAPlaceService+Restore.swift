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
            case .planned:
                // A confirmed plan stays open for a shorter roster or a
                // call-off; one this phone cannot rebuild is retired.
                let rebuilt = interaction.role == .initiator ? await resumeSettled(interaction) : resumePlannedInvite(interaction)
                if !rebuilt { try? await outbox.retire(interaction.conversation) }
                continue
            case .done, .ended:
                // Retired on every ending (ADR 0021), again here in case the
                // app stopped before it did; a yes still being taken back is
                // retired once the organizer hears it.
                if pendingWithdrawals[interaction.conversation] == nil { try? await outbox.retire(interaction.conversation) }
                continue
            default: break
            }
            let conversation = interaction.conversation
            let isNew = conversationOf[interaction.id] == nil && organized[conversation] == nil && invites[conversation] == nil
            var resumed = false
            if isNew, interaction.skill.version.isCompatible(with: descriptor.ref.version) {
                resumed = interaction.role == .initiator ? await resumeOrganizer(interaction) : await resumeInvite(interaction)
            }
            if !resumed {
                try? await outbox.retire(conversation)
                emit(interaction.id, .failed)
            }
        }
    }

    /// A settled organizer that can repeat its confirmation, from the stored
    /// proposal and the attendees it produced.
    @discardableResult
    private func resumeSettled(_ interaction: Interaction) async -> Bool {
        let conversation = interaction.conversation
        // Read before anything is checked, so nothing changes between the
        // checks and the rebuild. A change of place stays one that needs
        // everyone, so a yes taken back still calls it off; unreadable, it
        // is treated as a first place, which leaves the others in the plan.
        let everyoneMustAgree = (try? await ledger.deadlines(for: conversation))?.everyoneMustAgree ?? false
        guard organized[conversation] == nil, let proposal = interaction.proposal, let (place, roster) = Self.parts(of: proposal),
              roster.first == localPeer, let attendees = Self.attendees(of: interaction)
        else { return false }
        var values = proposal.terms.values
        values[.people] = .peers(attendees)
        var organizer = Organizer(
            id: interaction.id, conversation: conversation, chainedFrom: interaction.chain?.parentConversation,
            friends: Array(roster.dropFirst()), ranking: [place], base: proposal.plan,
            everyoneMustAgree: everyoneMustAgree, time: nil, activity: nil
        )
        organizer.phase = .settled
        organizer.proposal = proposal
        organizer.ownerAccepted = true
        organizer.accepted = Set(attendees.filter { $0 != localPeer })
        organizer.finalTerms = try? Terms(values)
        organized[conversation] = organizer
        conversationOf[interaction.id] = conversation
        rememberOrganizer(conversation)
        return true
    }

    static func attendees(of interaction: Interaction) -> [PeerID]? {
        interaction.artifacts.compactMap { if case .attendees(let people) = $0 { people.peers } else { nil } }.last
    }

    /// A friend's confirmed plan, so a shorter roster or a call-off still
    /// reaches it, and it can still be withdrawn.
    private func resumePlannedInvite(_ interaction: Interaction) -> Bool {
        let conversation = interaction.conversation
        guard invites[conversation] == nil, let proposal = interaction.proposal, let (place, _) = Self.parts(of: proposal),
              let roster = Self.attendees(of: interaction), let organizer = roster.first, organizer != localPeer, roster.contains(localPeer)
        else { return false }
        var invite = Invite(id: interaction.id, conversation: conversation, organizer: organizer, chainedFrom: interaction.friendChainHint,
                            candidates: [place])
        invite.announced = true
        invite.admitted = true
        invite.acceptable = [place]
        invite.revision = proposal.revision
        invite.proposal = proposal
        invite.accepted = true
        invite.finished = true
        invite.finalRoster = roster
        invites[conversation] = invite
        conversationOf[interaction.id] = conversation
        return true
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
            friends: Array(roster.dropFirst()), ranking: [place], base: proposal.plan,
            everyoneMustAgree: false, time: time, activity: activity
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
        organized[conversation]?.everyoneMustAgree = deadlines.everyoneMustAgree
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
            // A retired conversation is never resumed. The organizer's next
            // query sets the candidates; the Outbox keeps the conversation
            // within its answer budget across relaunches (ADR 0021).
            guard let retired = try? await conversations.isRetired(conversation), !retired else { return false }
            var invite = Invite(id: interaction.id, conversation: conversation, organizer: organizer, chainedFrom: interaction.friendChainHint,
                                candidates: [])
            invite.announced = true
            invite.admitted = true
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
            invite.admitted = true
            // This phone already found the proposed place acceptable.
            invite.acceptable = [place]
            invite.revision = proposal.revision
            invite.proposal = proposal
            // The offer itself was not stored; its terms are what a yes
            // repeats, and the round it named is the agreed plan's revision,
            // so they stand for it.
            let round = UInt16(min(proposal.plan?.revision ?? 0, UInt32(ProtocolLimits.maxNegotiationRounds - 1)))
            invite.offer = try? Proposal(round: round, terms: proposal.terms)
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
