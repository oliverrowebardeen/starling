import Foundation
import StarlingCore

// Starting a chained skill (ADR 0012, ADR 0240). Nothing starts without the
// owner's tap, and a link that adds a topic or permission also needs the
// owner's approval of exactly what it adds. Both are checked again against
// the current interactions, settings, and cards, because the group or the
// owner's settings may have changed since the row was drawn.

public enum ChainError: Error, Hashable, Sendable {
    /// The row is no longer offered: the parent is no longer a plan, someone
    /// in it lost the skill, or the owner switched it off or blocked it.
    case notOffered(SkillID)
    /// The row starts at Confirm and was asked to wait for the plan's end,
    /// or the other way round.
    case wrongTrigger(ChainTrigger)
    /// The link adds these topics or permissions, and the owner has not
    /// approved them for this plan and skill.
    case consentRequired(SkillExposure)
    /// The owner already opted into this after-plan-ends skill.
    case alreadyScheduled(InteractionID)
    /// The interaction is not an after-plan-ends link waiting to start.
    case notScheduled(InteractionID)
    /// The friend a change would add is already in the plan, is this phone,
    /// is not a friend whose card runs the skill, or the roster changes more
    /// than one person (ADR 0022 decision 5).
    case cannotAdd
}

/// A link ready to start: the interaction to save first, then the request
/// to hand the skill's service. Every envelope of the link carries
/// `request.chainedFrom`.
public struct ChainStart: Hashable, Sendable {
    public let interaction: Interaction
    public let request: SkillRequest
}

extension ChainPlanner {
    /// Starts an at-Confirm link ("Somewhere else?") after the owner's tap,
    /// with `consent` when the row needs one. Returns the new interaction,
    /// in drafting, with a `ChainLink` recording the tap as `optedInAt`.
    public func begin(
        _ suggestion: ChainSuggestion,
        in interactions: [Interaction],
        settings: SkillSettings,
        cards: [PeerID: AgentCard],
        tap: OwnerTap,
        consent: LinkConsent?,
        rules: OwnerRules,
        expiresAt: Timestamp
    ) throws -> ChainStart {
        let row = try current(suggestion, in: interactions, settings: settings, cards: cards)
        guard row.trigger == .atConfirm else { throw ChainError.wrongTrigger(row.trigger) }
        try check(consent, for: row)
        let link = Self.link(for: row, at: tap.at)
        guard let parent = interactions.first(where: { $0.id == row.parent }) else { throw ChainError.notOffered(row.id) }
        return ChainStart(interaction: link, request: Self.request(for: link, mode: row.skill.defaultSendMode, inputs: Self.inputs(row.consumes, from: parent),
                                                                   rules: rules, expiresAt: expiresAt))
    }

    /// Opts into an after-plan-ends skill ("Swap photos after") at Confirm.
    /// The returned interaction waits in drafting until the plan ends; the
    /// app saves it, and `PlanEndSchedule` starts it then. Approving the
    /// fresh Consent here is what lets it start without another tap.
    public func optIn(
        _ suggestion: ChainSuggestion,
        in interactions: [Interaction],
        settings: SkillSettings,
        cards: [PeerID: AgentCard],
        tap: OwnerTap,
        consent: LinkConsent?
    ) throws -> Interaction {
        let row = try current(suggestion, in: interactions, settings: settings, cards: cards)
        guard row.trigger == .afterPlanEnds else { throw ChainError.wrongTrigger(row.trigger) }
        if let scheduled = row.scheduled { throw ChainError.alreadyScheduled(scheduled) }
        try check(consent, for: row)
        return Self.link(for: row, at: tap.at)
    }

    /// The owner switched "Swap photos after" off before the plan ended.
    /// Returns the waiting interaction to remove: nothing ran and nothing
    /// left the phone, so there is nothing to keep in history.
    public func optOut(_ waiting: Interaction, tap: OwnerTap) throws -> InteractionID {
        guard Self.isWaitingForPlanEnd(waiting) else { throw ChainError.notScheduled(waiting.id) }
        return waiting.id
    }

    /// The parent with its plan updated by what a finished link agreed:
    /// the place ("Somewhere else?") and the people who agreed to it, with
    /// the plan's revision one higher (ADR 0022). The link is an owner link
    /// or a friend's request grouped under the plan, so the plan changes the
    /// same way on every phone. Applying the same link again changes nothing. A
    /// friend who passed on the link drops out of the plan, so no later chain
    /// reaches them (ADR 0020 decision 9.3). A link can only narrow the
    /// roster: attendees outside the plan, or a roster without this phone,
    /// are ignored. Nil if the link is not a planned link of this parent or
    /// agreed nothing new. The app saves the result.
    public func parent(_ parent: Interaction, updatedBy link: Interaction) -> Interaction? {
        guard Self.isLink(link, of: parent), link.state == .planned || link.state == .done,
              let plan = parent.plan
        else { return nil }
        let place = link.artifacts.lazy.compactMap({ if case .placeChoice(let place) = $0 { place } else { nil } }).first
        var agreed: Attendees?
        if let attendees = link.artifacts.lazy.compactMap({ if case .attendees(let attendees) = $0 { attendees } else { nil } }).first,
           attendees.peers.contains(me), Set(attendees.peers).isSubset(of: plan.attendees.peers) {
            agreed = attendees
        }
        let newPlace = place ?? plan.place
        let newAttendees = agreed ?? plan.attendees
        // Already applied (or nothing new): the revision must not rise again.
        guard newPlace != plan.place || newAttendees != plan.attendees else { return nil }
        // Through Plan.updating, so the plan's revision rises by one (ADR 0022).
        guard let updatedPlan = try? plan.updating(attendees: newAttendees, place: .some(newPlace)) else { return nil }
        var updated = parent
        updated.record(.plan(updatedPlan))
        return updated
    }

    /// Whether `link` continues `parent`'s plan: an owner link, or a friend's
    /// request the coordinator grouped under the plan by its hint. Both
    /// update the plan on this phone, so every phone keeps the same plan and
    /// revision.
    static func isLink(_ link: Interaction, of parent: Interaction) -> Bool {
        if link.chain?.parent == parent.id { return true }
        guard link.role == .invitee, link.chain == nil, let hint = link.friendChainHint else { return false }
        return hint == parent.planConversation
    }

    // MARK: - Helpers

    /// The row as it stands now, or `notOffered`.
    private func current(_ suggestion: ChainSuggestion, in interactions: [Interaction], settings: SkillSettings, cards: [PeerID: AgentCard]) throws -> ChainSuggestion {
        guard let row = suggestions(after: suggestion.parent, in: interactions, settings: settings, cards: cards)
            .first(where: { $0.id == suggestion.id && $0.skill.ref == suggestion.skill.ref })
        else { throw ChainError.notOffered(suggestion.id) }
        return row
    }

    /// A row that adds nothing needs only the tap. Otherwise the owner must
    /// have approved, for this plan and this skill, at least what it adds
    /// now, which may be more than when the row was drawn.
    private func check(_ consent: LinkConsent?, for row: ChainSuggestion) throws {
        guard row.needsConsent else { return }
        guard let consent, consent.parent == row.parent, consent.skill == row.skill.ref,
              row.adds.adding(over: consent.approved).isEmpty
        else { throw ChainError.consentRequired(row.adds) }
    }

    static func link(for row: ChainSuggestion, at time: Timestamp) -> Interaction {
        Interaction(
            skill: row.skill.ref,
            role: .initiator,
            participants: row.participants,
            createdAt: time,
            chain: ChainLink(parent: row.parent, parentConversation: row.parentConversation, consumed: row.consumes, trigger: row.trigger, optedInAt: time)
        )
    }

    static func inputs(_ kinds: [ArtifactKind], from parent: Interaction) -> [Artifact] {
        kinds.compactMap { kind in parent.artifacts.first { $0.kind == kind } }
    }

    /// A link goes only to the people `ChainSuggestion.participants` named:
    /// the parent plan's attendees, so `chainedFrom` never names a
    /// conversation a recipient was not in (ADR 0020 decision 9.3). Chains
    /// use the skill's default mode; Compose's choice is not asked again.
    static func request(for link: Interaction, mode: SendMode, inputs: [Artifact], rules: OwnerRules, expiresAt: Timestamp) -> SkillRequest {
        SkillRequest(
            interaction: link.id,
            conversation: link.conversation,
            intent: SkillIntent(skill: link.skill, rules: rules, audience: .picked(link.participants), mode: mode, expiresAt: expiresAt),
            participants: link.participants,
            inputs: inputs,
            chainedFrom: link.chain?.parentConversation
        )
    }
}
