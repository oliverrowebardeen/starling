import Foundation
import StarlingCore

// Change the plan (ADR 0022, ADR 0243). A suggestion is its own chained
// interaction, started by the owner from the plan's detail while the plan
// stands (`ChainTrigger.whilePlanned`), never offered under "Keep it going".
// These are its chaining rules: when it is offered, who it goes to, what
// consent it needs, and leaving. The skill itself is
// `Packages/Skills/ChangePlan`.

extension ChainPlanner {
    /// The highest plan revision a suggestion can change. A suggestion names
    /// the revision it changes in `Proposal.round`, which must stay below
    /// `ProtocolLimits.maxNegotiationRounds` (`docs/requests/P15-E.md`).
    public static let maxChangeableRevision = UInt32(ProtocolLimits.maxNegotiationRounds - 1)

    /// "Suggest a change" for the plan `parent` holds, or nil when it cannot
    /// be offered: the plan is not standing (not planned, or ended), its
    /// revision is at the limit, the skill is not available here, anyone in
    /// the plan lacks it or has no card on this phone, or a suggestion for
    /// this plan is already open (the owner's or a friend's, ADR 0022
    /// decision 6). `adds` says what a fresh Consent must cover.
    public func changeOffer(for parent: InteractionID, in interactions: [Interaction], settings: SkillSettings,
                            cards: [PeerID: AgentCard], now: Date) -> ChainSuggestion? {
        guard let root = interactions.first(where: { $0.id == parent }), root.state == .planned, let plan = root.plan,
              plan.revision < Self.maxChangeableRevision,
              let descriptor = registry.descriptor(for: .changePlan), descriptor.chainTrigger == .whilePlanned,
              registry.availability(of: .changePlan, in: settings).isAvailable
        else { return nil }
        if let end = plan.endsAt, now >= end { return nil }
        let others = participants(of: root)
        guard !others.isEmpty,
              others.allSatisfy({ cards[$0]?.support(for: descriptor.ref).isSupported == true }),
              Self.openChange(for: root, in: interactions) == nil
        else { return nil }
        return ChainSuggestion(
            skill: descriptor, parent: root.id, parentConversation: root.planConversation, consumes: [.plan], participants: others,
            adds: descriptor.exposure.adding(over: grantedExposure(for: root, in: interactions)), startsAfter: nil, scheduled: nil
        )
    }

    /// The suggestion still open for the plan `root` holds: the owner's own
    /// (a link) or a friend's (an invitee grouped under the plan by its
    /// hint), until it settles.
    public static func openChange(for root: Interaction, in interactions: [Interaction]) -> Interaction? {
        interactions.first { item in
            guard item.skill.id == .changePlan, isWorking(item.state) else { return false }
            if item.chain?.parent == root.id { return true }
            return item.role == .invitee && item.friendChainHint == root.planConversation
        }
    }

    /// Starts a suggestion after the owner's tap, with `consent` when the
    /// offer adds anything. `rules` and `extraInputs` carry the change, as
    /// the Change the plan skill encodes it. An `.attendees` input is a
    /// friend added to the plan: the roster must be the plan's people plus
    /// exactly one more, a friend of this phone whose card runs the skill
    /// (ADR 0022 decision 5). The request goes to everyone else in the plan.
    public func beginChange(
        _ suggestion: ChainSuggestion,
        in interactions: [Interaction],
        settings: SkillSettings,
        cards: [PeerID: AgentCard],
        now: Date,
        tap: OwnerTap,
        consent: LinkConsent?,
        rules: OwnerRules,
        extraInputs: [Artifact],
        expiresAt: Timestamp
    ) throws -> ChainStart {
        guard let row = changeOffer(for: suggestion.parent, in: interactions, settings: settings, cards: cards, now: now),
              row.skill.ref == suggestion.skill.ref,
              let parent = interactions.first(where: { $0.id == row.parent }), let plan = parent.plan
        else { throw ChainError.notOffered(.changePlan) }
        try checkChangeConsent(consent, for: row)
        for case .attendees(let roster) in extraInputs {
            let added = roster.peers.filter { !plan.attendees.peers.contains($0) }
            guard roster.peers.count == plan.attendees.peers.count + 1, Array(roster.peers.prefix(plan.attendees.peers.count)) == plan.attendees.peers,
                  let friend = added.first, added.count == 1, friend != me,
                  cards[friend]?.support(for: row.skill.ref).isSupported == true
            else { throw ChainError.cannotAdd }
        }
        let link = Self.link(for: row, at: tap.at)
        return ChainStart(interaction: link, request: Self.request(for: link, mode: row.skill.defaultSendMode,
                                                                   inputs: [.plan(plan)] + extraInputs, rules: rules, expiresAt: expiresAt))
    }

    /// Leaves the plan `parent` holds (ADR 0022 decision 5). Needs no
    /// agreement and no fresh Consent: leaving discloses nothing but that
    /// you left. Allowed while the plan stands, even with a suggestion open.
    /// `rules` carries the leave, as the Change the plan skill encodes it.
    public func beginLeave(from parent: InteractionID, in interactions: [Interaction], settings: SkillSettings,
                           tap: OwnerTap, rules: OwnerRules, expiresAt: Timestamp) throws -> ChainStart {
        guard let root = interactions.first(where: { $0.id == parent }), root.state == .planned, let plan = root.plan,
              let descriptor = registry.descriptor(for: .changePlan),
              registry.availability(of: .changePlan, in: settings).isAvailable
        else { throw ChainError.notOffered(.changePlan) }
        let link = Interaction(
            skill: descriptor.ref, role: .initiator, participants: participants(of: root), createdAt: tap.at,
            chain: ChainLink(parent: root.id, parentConversation: root.planConversation, consumed: [.plan], trigger: .whilePlanned,
                             optedInAt: tap.at)
        )
        return ChainStart(interaction: link, request: Self.request(for: link, mode: descriptor.defaultSendMode, inputs: [.plan(plan)],
                                                                   rules: rules, expiresAt: expiresAt))
    }

    private func checkChangeConsent(_ consent: LinkConsent?, for row: ChainSuggestion) throws {
        guard row.needsConsent else { return }
        guard let consent, consent.parent == row.parent, consent.skill == row.skill.ref,
              row.adds.adding(over: consent.approved).isEmpty
        else { throw ChainError.consentRequired(row.adds) }
    }
}
