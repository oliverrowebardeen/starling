import Foundation
import StarlingCore

// Resuming after a restart (ADR 0222). The coordinator's stored
// `Interaction` is the truth for the lifecycle (state, revisions, the
// pending question or proposal); the service's checkpoint adds what only
// the service knows (the offered times, friends' answers, envelope IDs).

extension FindATimeService {
    func resume(_ interactions: [Interaction], from saved: [FindATimeCheckpoint]) {
        let checkpoints = Dictionary(saved.map { ($0.interaction, $0) }, uniquingKeysWith: { _, last in last })
        var live: Set<InteractionID> = []

        for stored in interactions where stored.skill.id == FindATimeSkill.ref.id && !stored.state.isFinal {
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

    private func resumeInitiating(_ saved: Initiating, as interaction: Interaction) {
        var value = saved
        value.interaction = interaction
        switch interaction.state {
        case .planned:
            value.phase = .planned
        case .confirmed:
            value.ownerAccepted = true
        case .awaitingOwner:
            value.phase = .askingOwner
        default:
            break
        }
        guard value.phase != .resolving, value.phase != .askingOwner || interaction.pendingQuestion != nil else {
            // A restart while reading the calendar: the read is gone, and
            // the range it covered was not saved.
            return reportFailed(interaction)
        }
        let id = value.conversation
        initiating[id] = value
        register(id, interaction: interaction.id)
        checkpoint(id)
        switch value.phase {
        case .planned where interaction.state == .confirmed:
            // Confirmed on the wire, but the plan never reached the store.
            if let revision = value.draft?.revision { confirmationsDone(id, revision: revision, refusal: nil) }
        case .collecting:
            initiatorResend(id, to: value.waitingOn)
        case .proposing:
            if let draft = value.draft, interaction.proposalRevision != draft.revision {
                // The card never went up before the restart. Send and show
                // it again; friends that already have it treat it as a retry.
                proposeAgain(id, draft)
            } else {
                initiatorResend(id, to: value.waitingOn)
            }
        default:
            break
        }
    }

    private func resumeInvited(_ saved: Invited, as interaction: Interaction) {
        var value = saved
        value.interaction = interaction
        switch interaction.state {
        case .planned: value.phase = .planned
        case .confirmed: value.phase = .accepted
        case .proposed: value.phase = value.offer == nil ? value.phase : .proposed
        case .awaitingOwner: value.phase = .askingOwner
        default: break
        }
        if value.phase == .askingOwner, interaction.pendingQuestion == nil {
            // The question never reached the store: ask it again.
            value.phase = .resolving
        }
        if value.phase == .proposed, let offer = value.offer, interaction.proposalRevision != offer.revision {
            // The card never reached the store: show it again.
            let card = SkillProposal(revision: offer.revision, participants: offer.plan.attendees.peers, terms: offer.terms, plan: offer.plan)
            if !emit(.proposalReady(card), to: &value.interaction) { value.phase = .answered }
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
