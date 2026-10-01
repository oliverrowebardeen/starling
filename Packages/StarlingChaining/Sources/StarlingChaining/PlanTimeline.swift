import Foundation
import StarlingCore

/// "How this came together" for a plan (mockup "Plan detail"): the plan's
/// first interaction, every link chained after it, and every friend's
/// chained request grouped under it, in the order they started, with "What
/// left your phone" across all of them. Hand-offs such as Add to Calendar
/// are the app's to add; they are not interactions.
public struct PlanTimeline: Hashable, Sendable {
    public struct Entry: Hashable, Sendable, Identifiable {
        public enum Origin: Hashable, Sendable {
            /// The interaction the plan came from.
            case plan
            /// A link the owner started or opted into, with the tap.
            case chained(ChainTrigger, optedInAt: Timestamp)
            /// A friend's agent continued the plan with this request. Shown on
            /// the timeline only; it started nothing on this phone.
            case friend
        }

        public let id: InteractionID
        public let skill: SkillRef
        /// The skill's name ("Pick a place"), or nil if this build does not
        /// register it.
        public let name: String?
        public let origin: Origin
        public let role: InteractionRole
        public let state: InteractionState
        public let startedAt: Timestamp
        public let updatedAt: Timestamp
        /// While an after-plan-ends link waits: when it starts ("After 10:30 PM").
        public let startsAfter: Date?
        public let participants: [PeerID]
        public let artifacts: [Artifact]
        public let history: [StateChange]
    }

    public let root: InteractionID
    public let entries: [Entry]
    public let whatLeft: WhatLeftYourPhone

    /// The timeline of the plan `interaction` belongs to, or nil if it is not
    /// in `interactions`. A friend's request joins through its
    /// `Interaction.friendChainHint`, which the coordinator sets only after
    /// `IncomingChain.timelineParent` accepted the request's `chainedFrom`.
    /// `unconfirmed` is `EgressRecorder.unconfirmedConversations`, for
    /// `whatLeft`.
    public init?(for interaction: InteractionID, in interactions: [Interaction], registry: SkillRegistry, unconfirmed: Set<ConversationID> = []) {
        guard let start = interactions.first(where: { $0.id == interaction }) else { return nil }
        func parent(of item: Interaction) -> Interaction? {
            if let id = item.chain?.parent { return interactions.first { $0.id == id } }
            // Only a friend's request without an owner link groups by a hint.
            if item.role == .invitee, let hint = item.friendChainHint { return interactions.first { $0.conversation == hint } }
            return nil
        }

        var root = start
        var seen: Set<InteractionID> = [root.id]
        while let next = parent(of: root), seen.insert(next.id).inserted { root = next }

        var members: [Interaction] = [root]
        var included: Set<InteractionID> = [root.id]
        var grew = true
        while grew {
            grew = false
            for item in interactions where !included.contains(item.id) {
                if let up = parent(of: item), included.contains(up.id) {
                    members.append(item)
                    included.insert(item.id)
                    grew = true
                }
            }
        }
        members.sort { $0.createdAt < $1.createdAt }

        self.root = root.id
        entries = members.map { item in
            let origin: Entry.Origin = if item.id == root.id {
                .plan
            } else if let link = item.chain {
                .chained(link.trigger, optedInAt: link.optedInAt)
            } else {
                .friend
            }
            let startsAfter = ChainPlanner.isWaitingForPlanEnd(item) ? parent(of: item)?.plan?.endsAt : nil
            return Entry(
                id: item.id, skill: item.skill, name: registry.descriptor(for: item.skill.id)?.wording.name, origin: origin,
                role: item.role, state: item.state, startedAt: item.createdAt, updatedAt: item.updatedAt, startsAfter: startsAfter,
                participants: item.participants, artifacts: item.artifacts, history: item.history
            )
        }
        whatLeft = WhatLeftYourPhone(interactions: members, registry: registry, unconfirmed: unconfirmed)
    }
}
