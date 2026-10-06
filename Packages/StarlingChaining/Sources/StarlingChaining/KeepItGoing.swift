import Foundation
import StarlingCore

// "Keep it going" (ADR 0012, ADR 0240). After a plan, the owner sees the
// skills that can follow it. A row appears only when this phone can run the
// skill, every other person in the plan supports it, and the plan produced
// something the skill accepts. Each row says what the skill would add over
// what the owner already allowed for the plan, so the app knows whether a
// fresh Consent must run before the link starts.

/// One "Keep it going" row.
public struct ChainSuggestion: Hashable, Sendable, Identifiable {
    public let skill: SkillDescriptor
    /// The interaction the link would follow, and its conversation, which
    /// every envelope of the link carries as `chainedFrom`.
    public let parent: InteractionID
    public let parentConversation: ConversationID
    /// The artifact kinds the link takes from the parent, in `ArtifactKind`
    /// declaration order.
    public let consumes: [ArtifactKind]
    /// Everyone else in the plan. The link goes to all of them.
    public let participants: [PeerID]
    /// Topics and permissions the skill adds over what the owner already
    /// allowed for this plan. Non-empty means a fresh Consent first.
    public let adds: SkillExposure
    /// For an after-plan-ends skill: when it would start.
    public let startsAfter: Date?
    /// For an after-plan-ends skill the owner already opted into: the
    /// waiting interaction, so the switch shows on.
    public let scheduled: InteractionID?

    public var id: SkillID { skill.id }
    public var trigger: ChainTrigger { skill.chainTrigger }
    public var needsConsent: Bool { !adds.isEmpty }

    /// The owner's approval of this row's fresh Consent, from the sheet that
    /// listed `adds`.
    public func consent(approvedAt time: Timestamp) -> LinkConsent {
        LinkConsent(parent: parent, skill: skill.ref, approved: adds, at: time)
    }
}

/// The owner approved what a chained skill adds, on the sheet the app shows
/// before the link starts.
public struct LinkConsent: Hashable, Sendable {
    public let parent: InteractionID
    public let skill: SkillRef
    public let approved: SkillExposure
    public let at: Timestamp

    public init(parent: InteractionID, skill: SkillRef, approved: SkillExposure, at: Timestamp) {
        self.parent = parent
        self.skill = skill
        self.approved = approved
        self.at = at
    }
}

/// The owner tapped a "Keep it going" row or switch. Only the app's tap
/// handlers create one; nothing a peer sends can (ARCHITECTURE rule 8).
public struct OwnerTap: Hashable, Sendable {
    public let at: Timestamp

    public init(at: Timestamp) { self.at = at }
}

/// Suggests chains and starts them. Pure: the app passes the interactions,
/// settings, and cards it holds, and saves what comes back.
public struct ChainPlanner: Sendable {
    public let registry: SkillRegistry
    /// This phone's peer ID, so a plan's attendees can be turned into the
    /// people a link goes to.
    public let me: PeerID

    public init(registry: SkillRegistry, me: PeerID) {
        self.registry = registry
        self.me = me
    }

    /// The "Keep it going" rows for `parent`, in registry order. Empty unless
    /// the parent is planned. A row the group cannot run is left out, not
    /// shown and failed: that includes anyone in the plan whose card this
    /// phone does not have.
    public func suggestions(
        after parent: InteractionID,
        in interactions: [Interaction],
        settings: SkillSettings,
        cards: [PeerID: AgentCard]
    ) -> [ChainSuggestion] {
        guard let root = interactions.first(where: { $0.id == parent }), root.state == .planned else { return [] }
        let others = participants(of: root)
        guard !others.isEmpty else { return [] }
        var peerCards: [AgentCard] = []
        for peer in others {
            guard let card = cards[peer] else { return [] }
            peerCards.append(card)
        }
        let produced = Set(root.artifacts.map(\.kind))
        let granted = grantedExposure(for: root, in: interactions)
        let links = interactions.filter { $0.chain?.parent == root.id }

        return registry.chainSuggestions(after: root.skill.id, in: settings, peers: peerCards).compactMap { next in
            let consumes = ArtifactKind.allCases.filter { next.accepts.contains($0) && produced.contains($0) }
            guard !consumes.isEmpty else { return nil }
            let sameSkill = links.filter { $0.skill.id == next.id && Self.isWorking($0.state) }
            var startsAfter: Date?
            var scheduled: InteractionID?
            switch next.chainTrigger {
            case .atConfirm:
                // One working link per skill: "Somewhere else?" again only
                // once the last one has settled.
                guard sameSkill.isEmpty else { return nil }
            case .afterPlanEnds:
                guard let end = root.plan?.endsAt else { return nil }
                startsAfter = end
                let waiting = sameSkill.filter(Self.isWaitingForPlanEnd)
                guard waiting.count == sameSkill.count else { return nil }
                scheduled = waiting.first?.id
            case .whilePlanned:
                // Change the plan is started from the plan's detail, not
                // offered under "Keep it going" (ADR 0022).
                return nil
            }
            return ChainSuggestion(
                skill: next,
                parent: root.id,
                parentConversation: root.planConversation,
                consumes: consumes,
                participants: others,
                adds: next.exposure.adding(over: granted),
                startsAfter: startsAfter,
                scheduled: scheduled
            )
        }
    }

    /// Whether `interaction` is an after-plan-ends link the owner opted into
    /// that has not started yet.
    public static func isWaitingForPlanEnd(_ interaction: Interaction) -> Bool {
        interaction.role == .initiator && interaction.state == .drafting && interaction.chain?.trigger == .afterPlanEnds
    }

    /// Everyone in the plan but this phone, in plan order. Only the plan's
    /// attendees: a chain never reaches anyone the plan did not include, so
    /// `chainedFrom` never names a conversation a recipient was not in (ADR
    /// 0020 decision 9.3). Without a plan there is nobody to chain with.
    func participants(of interaction: Interaction) -> [PeerID] {
        var seen: Set<PeerID> = [me]
        return (interaction.plan?.attendees.peers ?? []).filter { seen.insert($0).inserted }
    }

    /// What the owner already allowed for the plan `interaction` belongs to:
    /// the topics and permissions of every skill in its chain that the owner
    /// said yes to (confirmed, planned, or done). A link the owner declined
    /// or that never got a yes grants nothing.
    ///
    /// The owner approved a skill at the version that ran, so only that exact
    /// `SkillRef` counts. If this build registers another version (one that
    /// may use more topics or permissions), what was approved is unknown and
    /// the interaction grants nothing, so a link that adds anything asks
    /// again.
    public func grantedExposure(for interaction: Interaction, in interactions: [Interaction]) -> SkillExposure {
        let root = Self.root(of: interaction, in: interactions)
        return interactions.chain(from: root).reduce(SkillExposure.none) { granted, item in
            guard item.history.contains(where: { Self.ownerSaidYes($0.state) }),
                  let descriptor = registry.descriptor(for: item.skill.id), descriptor.ref == item.skill
            else { return granted }
            return granted.union(descriptor.exposure)
        }
    }

    /// The first interaction of the plan `interaction` belongs to, following
    /// owner chain links only. Stops on a missing parent or a cycle.
    public static func root(of interaction: Interaction, in interactions: [Interaction]) -> InteractionID {
        var current = interaction
        var seen: Set<InteractionID> = [current.id]
        while let parent = current.chain?.parent,
              let next = interactions.first(where: { $0.id == parent }),
              seen.insert(next.id).inserted {
            current = next
        }
        return current.id
    }

    /// Still on its way to a plan: anything before planned that has not ended.
    static func isWorking(_ state: InteractionState) -> Bool {
        state != .planned && !state.isFinal
    }

    private static func ownerSaidYes(_ state: InteractionState) -> Bool {
        switch state {
        case .confirmed, .planned, .done: true
        default: false
        }
    }
}
