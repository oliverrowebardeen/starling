import Foundation
import StarlingCore

// Resuming after a restart (ADR 0222). The coordinator's stored
// `Interaction` is the truth for the lifecycle (state, revisions, the
// pending question or proposal, and whether the owner accepted); the
// service's checkpoint adds what only the service knows (the offered
// times, friends' answers, envelope IDs, which sends have left).
//
// The two can disagree when the app dies between their writes. An
// acceptance, the owner's or this phone's, is resumed only when the stored
// proposal is the same revision with the same terms as the checkpoint's; a
// newer proposal in the checkpoint is shown again for a fresh acceptance.
// A plan is recovered only from evidence that it was completed.

extension FindATimeService {
    func resume(_ interactions: [Interaction], from saved: [FindATimeCheckpoint]) {
        let checkpoints = Dictionary(saved.map { ($0.interaction, $0) }, uniquingKeysWith: { _, last in last })
        let mine = interactions.filter { $0.skill.id == FindATimeSkill.ref.id }

        // Interactions that ended recently (ADR 0011, amendment 15) become
        // tombstones first, so a late retry for one is never opened again.
        for ended in mine where ended.state.isFinal {
            remember(ended.conversation, asker: ended.role == .invitee ? ended.participants.first : nil, interaction: ended.id)
        }

        var live: Set<InteractionID> = []
        for stored in mine where !stored.state.isFinal {
            guard conversationOf[stored.id] == nil, initiating[stored.conversation] == nil, invited[stored.conversation] == nil else { continue }
            live.insert(stored.id)
            let interaction = Self.withoutConsent(stored)
            switch checkpoints[stored.id]?.state {
            case .initiating(let value)?:
                resumeInitiating(value, as: interaction)
            case .invited(let value)?:
                resumeInvited(value, as: interaction)
            case nil:
                // Nothing to resume from. A plan already made stands; anything
                // else is reported failed rather than left hanging.
                if stored.state != .planned { reportFailed(interaction) }
            }
        }
        for checkpoint in saved where !live.contains(checkpoint.interaction) {
            removeCheckpoint(checkpoint.interaction)
        }
    }

    /// Whether the stored proposal is the checkpoint's: same revision, same terms.
    private static func sameProposal(_ interaction: Interaction, revision: UInt32?, terms: Terms?) -> Bool {
        guard let revision, let terms, let stored = interaction.proposal else { return false }
        return stored.revision == revision && stored.terms == terms
    }

    private static func ownerAccepted(_ interaction: Interaction) -> Bool {
        interaction.state == .confirmed || interaction.state == .planned
    }

    private func resumeInitiating(_ saved: Initiating, as interaction: Interaction) {
        var value = saved
        value.interaction = interaction
        let id = value.conversation

        if interaction.state == .awaitingOwner {
            value.phase = .askingOwner
        }
        guard value.phase != .resolving, value.phase != .askingOwner || interaction.pendingQuestion != nil else {
            // A restart while reading the calendar: the read is gone, and
            // the range it covered was not saved.
            return reportFailed(interaction)
        }

        var showAgain: Draft?
        if let draft = value.draft, [.proposing, .confirming, .planned].contains(value.phase) {
            if Self.sameProposal(interaction, revision: draft.revision, terms: draft.terms) {
                // The owner's "That works" counts only if the store has it.
                value.ownerAccepted = Self.ownerAccepted(interaction)
                if interaction.state == .planned {
                    value.phase = .planned
                } else if !value.ownerAccepted {
                    value.phase = .proposing
                    value.confirmed = []
                }
            } else if (interaction.proposalRevision ?? 0) < draft.revision {
                // The card for this proposal never reached the store.
                value.phase = .proposing
                value.ownerAccepted = false
                value.confirmed = []
                showAgain = draft
            } else {
                return reportFailed(interaction)
            }
        }

        initiating[id] = value
        register(id, interaction: interaction.id)
        checkpoint(id)
        if let showAgain { return proposeAgain(id, showAgain) }
        switch value.phase {
        case .collecting, .proposing:
            initiatorResend(id, to: value.waitingOn)
        case .confirming:
            // Finish through Outbox, with a fresh sheet if the policy asks.
            sendConfirmations(id, to: value.waitingOn)
            finishPlanIfConfirmed(id)
        case .planned where interaction.state == .confirmed:
            // Every confirmation left (the checkpoint says planned only after
            // that), but the plan never reached the store.
            value.phase = .confirming
            initiating[id] = value
            finishPlanIfConfirmed(id)
        default:
            break
        }
    }

    private func resumeInvited(_ saved: Invited, as interaction: Interaction) {
        var value = saved
        value.interaction = interaction
        if interaction.state == .awaitingOwner {
            value.phase = .askingOwner
        }
        if value.phase == .askingOwner, interaction.pendingQuestion == nil {
            // The question never reached the store: ask it again.
            value.phase = .resolving
        }

        if let offer = value.offer, [.proposed, .accepted, .planned].contains(value.phase) {
            if Self.sameProposal(interaction, revision: offer.revision, terms: offer.terms) {
                switch interaction.state {
                case .planned: value.phase = .planned
                // Our acceptance counts only if the store has the owner's tap.
                case .confirmed: value.phase = .accepted
                default:
                    value.phase = .proposed
                    value.acceptanceLeft = nil
                    value.heldConfirmation = nil
                }
            } else if (interaction.proposalRevision ?? 0) < offer.revision {
                // A newer proposal than the store's: show it for a fresh "That works".
                let card = SkillProposal(revision: offer.revision, participants: offer.plan.attendees.peers, terms: offer.terms, plan: offer.plan)
                value.acceptanceLeft = nil
                value.heldConfirmation = nil
                value.phase = emit(.proposalReady(card), to: &value.interaction) ? .proposed : .answered
            } else {
                return reportFailed(interaction)
            }
        }

        let id = value.conversation
        invited[id] = value
        register(id, interaction: interaction.id)
        checkpoint(id)
        switch value.phase {
        case .resolving: resolveInvitation(id)
        case .accepted: inviteeResendAcceptance(id)
        default: break
        }
    }

    private func reportFailed(_ interaction: Interaction) {
        var copy = interaction
        emit(.failed, to: &copy)
        removeCheckpoint(interaction.id)
        remember(interaction.conversation, asker: interaction.role == .invitee ? interaction.participants.first : nil, interaction: interaction.id)
    }

    /// The service's copy never sees consent; a sheet open at the restart
    /// is gone with the old process, so resume from the step it interrupted.
    private static func withoutConsent(_ interaction: Interaction) -> Interaction {
        var copy = interaction
        for request in copy.pendingConsents.sorted() {
            try? copy.apply(.consentGiven(request: request), at: copy.updatedAt)
        }
        return copy
    }
}
