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
                let rebuilt = interaction.role == .initiator ? await resumeSettled(interaction) : await resumePlannedInvite(interaction)
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
        // checks and the rebuild.
        let kind = await organizerKind(of: interaction)
        // Each friend's counted yes, so a shorter roster still names what
        // the friend said yes to.
        let accepted = (try? await ledger.acceptedProposals(for: conversation)) ?? nil
        guard organized[conversation] == nil, let proposal = interaction.proposal, let (place, roster) = Self.parts(of: proposal),
              roster.first == localPeer, let attendees = Self.attendees(of: interaction)
        else { return false }
        var values = proposal.terms.values
        values[.people] = .peers(attendees)
        var organizer = Organizer(
            id: interaction.id, conversation: conversation, chainedFrom: interaction.chain?.parentConversation,
            friends: Array(roster.dropFirst()), ranking: [place], base: proposal.plan,
            kind: kind, time: nil, activity: nil
        )
        organizer.phase = .settled
        organizer.proposal = proposal
        organizer.ownerAccepted = true
        organizer.accepted = Set(attendees.filter { $0 != localPeer })
        organizer.acceptedProposal = accepted ?? [:]
        organizer.finalTerms = try? Terms(values)
        organized[conversation] = organizer
        conversationOf[interaction.id] = conversation
        rememberOrganizer(conversation)
        return true
    }

    /// The proposals this phone's yes named for `proposal`'s card, so a
    /// confirmation of that yes is still taken, and a repeated yes names
    /// one of them. A record for another card, or none, restores nothing:
    /// no confirmation is taken until the yes is said again.
    static func restore(_ yes: RecordedYes??, into invite: inout Invite, for proposal: SkillProposal) {
        guard let yes = yes ?? nil, yes.revision == proposal.revision else { return }
        invite.yesNamed = yes.proposals
        invite.proposeID = yes.proposals.last
    }

    /// The origin of this phone's own plan a friend's request names, which
    /// keys its hold (ADR 0023, decision 3); nil if this phone holds none.
    func planOrigin(of interaction: Interaction) async -> ConversationID? {
        guard let hint = interaction.friendChainHint else { return nil }
        return await plans(hint)?.origin
    }

    /// What a friend's request is on this phone's plan: none when it was
    /// not chained from one; otherwise the recorded kind, and a missing or
    /// unreadable one is read as a change of place no proposal can match
    /// (ADR 0233).
    func friendKind(of interaction: Interaction) async -> PlaceRequestKind? {
        guard interaction.friendChainHint != nil else { return nil }
        guard let recorded = try? await ledger.requestKind(for: interaction.conversation) else { return Self.unreadableKind }
        return recorded
    }

    /// What an organizer's request is on a plan. One not chained from a
    /// plan is on none. Otherwise the recorded kind; missing or unreadable,
    /// it is read as a change of place, so a relaunch never drops the rule
    /// that everyone must agree (ADR 0233).
    func organizerKind(of interaction: Interaction) async -> PlaceRequestKind? {
        guard interaction.chain != nil else { return nil }
        guard let recorded = try? await ledger.requestKind(for: interaction.conversation) else { return Self.unreadableKind }
        return recorded
    }

    static func attendees(of interaction: Interaction) -> [PeerID]? {
        interaction.artifacts.compactMap { if case .attendees(let people) = $0 { people.peers } else { nil } }.last
    }

    /// A friend's confirmed plan, so a shorter roster or a call-off still
    /// reaches it, and it can still be withdrawn.
    private func resumePlannedInvite(_ interaction: Interaction) async -> Bool {
        let conversation = interaction.conversation
        let kind = await friendKind(of: interaction)
        let origin = await planOrigin(of: interaction)
        let yes = try? await ledger.yes(for: conversation)
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
        invite.kind = kind
        invite.planOrigin = origin
        Self.restore(yes, into: &invite, for: proposal)
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
        // Read first, so nothing changes between the checks and the rebuild.
        let kind = await organizerKind(of: interaction)
        guard organized[interaction.conversation] == nil else { return false }
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
            kind: kind, time: time, activity: activity
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
        // Holds are not saved: a restored request on a plan holds it again,
        // and one that finds another change holding it ends, and the plan
        // stays as it was (ADR 0023).
        if let plan = organized[conversation]?.holdKey {
            guard await holds.hold(plan, for: conversation) else {
                endOrganizer(conversation, event: .noAgreement, reason: .noOverlap)
                return true
            }
        }
        startProposing(conversation)
        spawnExpiry(conversation, at: deadlines.expiresAt)
        return true
    }

    private func resumeInvite(_ interaction: Interaction) async -> Bool {
        let conversation = interaction.conversation
        let kind = await friendKind(of: interaction)
        let origin = await planOrigin(of: interaction)
        let yes = try? await ledger.yes(for: conversation)
        guard invites[conversation] == nil else { return false }
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
            invite.kind = kind
            invite.planOrigin = origin
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
            invite.kind = kind
            invite.planOrigin = origin
            Self.restore(yes, into: &invite, for: proposal)
            // A yes recorded for this card went out, even if the app stopped
            // before the interaction showed it (review of #118, round 2):
            // the yes stands, and the interaction catches up.
            let showedYes = Self.step(of: interaction.state) == .confirmed
            invite.accepted = showedYes || !invite.yesNamed.isEmpty
            invites[conversation] = invite
            conversationOf[interaction.id] = conversation
            spawnInviteDeadline(conversation)
            if invite.accepted, !showedYes { emit(interaction.id, .ownerAccepted(revision: proposal.revision)) }
            // A yes holds the plan again, as before the relaunch; if another
            // change holds it, this one ends (ADR 0023).
            if invite.accepted, let plan = invite.holdKey {
                guard await holds.hold(plan, for: conversation) else {
                    endInvite(conversation, event: .noAgreement, reply: nil)
                    return true
                }
            }
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
