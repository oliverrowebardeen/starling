import Foundation
import StarlingCore

/// "What left your phone" for a plan (mockup "Plan detail"): what was shared,
/// by topic, and what the plan's skills could have used but kept on the
/// phone. Built only from the egress logs, which hold the consent sheet's
/// own items (ADR 0011 decision 5), and the skills' descriptors. Lane A
/// renders it.
///
/// "Kept" is a claim that something never left, so it is made only from
/// interactions whose log is known to be complete. For any other, listed in
/// `unconfirmed`, its topics and permissions are left out of `kept` and the
/// app says it could not confirm everything that left during it. If such an
/// interaction ran a skill version this build does not register, what it
/// could have sent is unknown, and `kept` is empty.
public struct WhatLeftYourPhone: Hashable, Sendable {
    /// One topic that left the phone.
    public struct Shared: Hashable, Sendable {
        public let topic: PrivacyTopic
        /// Each distinct value, in the order it first left. Empty when the
        /// topic left only inside a private overlap check, which carries no
        /// readable value.
        public let values: [IssueValue]
        /// Who received it, in the order they first did.
        public let recipients: [PeerID]
        /// How many sends included it.
        public let sends: Int
    }

    /// Something the plan's skills use that stayed on the phone.
    public enum Kept: Hashable, Sendable {
        /// A topic a skill in the plan uses that never left.
        case topic(PrivacyTopic)
        /// What a system permission reads (the calendar, exact location, the
        /// photo library). Only derived values such as busy times leave, under
        /// their own topic.
        case permission(SystemPermission)
    }

    /// In `PrivacyTopic` order.
    public let shared: [Shared]
    /// Topics in `PrivacyTopic` order, then permissions.
    public let kept: [Kept]
    /// Items under no topic, each once: the agent card, a private overlap
    /// check that named no issue, or an issue no topic covers.
    public let other: [DisclosedItem]
    /// Every send recorded, including those that disclosed nothing.
    public let sends: Int
    /// Interactions whose egress log may be incomplete: a send's items were
    /// unknown, or `EgressRecorder` still has a write for its conversation
    /// waiting or lost. In the order given.
    public let unconfirmed: [InteractionID]

    /// `unconfirmed` is `EgressRecorder.unconfirmedConversations`.
    public init(interactions: [Interaction], registry: SkillRegistry, unconfirmed: Set<ConversationID> = []) {
        var values: [PrivacyTopic: [IssueValue]] = [:]
        var recipients: [PrivacyTopic: [PeerID]] = [:]
        var counts: [PrivacyTopic: Int] = [:]
        var other: [DisclosedItem] = []
        var sends = 0
        for record in interactions.flatMap(\.egress) {
            sends += 1
            var touched: Set<PrivacyTopic> = []
            for item in record.items {
                guard let topic = item.issue.flatMap(PrivacyTopic.init(issue:)) else {
                    if !other.contains(item) { other.append(item) }
                    continue
                }
                touched.insert(topic)
                if let value = item.value, !(values[topic] ?? []).contains(value) { values[topic, default: []].append(value) }
                if !(recipients[topic] ?? []).contains(record.recipient) { recipients[topic, default: []].append(record.recipient) }
            }
            for topic in touched { counts[topic, default: 0] += 1 }
        }

        let doubtful = interactions.filter { unconfirmed.contains($0.conversation) || !$0.egressIsKnown }
        let doubtfulIDs = Set(doubtful.map(\.id))
        // What a skill exposes, only for the exact version that ran: another
        // registered version may declare different topics.
        func exposure(of item: Interaction) -> SkillExposure? {
            guard let descriptor = registry.descriptor(for: item.skill.id), descriptor.ref == item.skill else { return nil }
            return descriptor.exposure
        }
        // What the confirmed interactions used, less anything an unconfirmed
        // one could have sent. A confirmed one whose version is unknown
        // claims nothing kept of its own. An unconfirmed one whose version is
        // unknown could have sent anything, so nothing is claimed kept at all.
        let vouched = interactions.filter { !doubtfulIDs.contains($0.id) }.compactMap(exposure(of:)).reduce(SkillExposure.none) { $0.union($1) }
        let unknownExposures = doubtful.map(exposure(of:))
        let used: Set<PrivacyTopic>
        let permissions: Set<SystemPermission>
        if unknownExposures.contains(where: { $0 == nil }) {
            used = []
            permissions = []
        } else {
            let unknown = unknownExposures.compactMap { $0 }.reduce(SkillExposure.none) { $0.union($1) }
            used = vouched.topics.subtracting(unknown.topics)
            permissions = vouched.permissions.subtracting(unknown.permissions)
        }

        shared = PrivacyTopic.allCases.compactMap { topic in
            counts[topic].map { Shared(topic: topic, values: values[topic] ?? [], recipients: recipients[topic] ?? [], sends: $0) }
        }
        kept = PrivacyTopic.allCases.filter { used.contains($0) && counts[$0] == nil }.map(Kept.topic)
            + SystemPermission.allCases.filter(permissions.contains).map(Kept.permission)
        self.other = other
        self.sends = sends
        self.unconfirmed = doubtful.map(\.id)
    }
}
