import Foundation

// Global privacy topics (Phase 1.5, ADR 0014). The owner sets one choice per
// topic, and it applies across every skill. Topics are a grouping of issues
// above the policy layer: `PrivacySettings.disclosureRules` expands them into
// the `DisclosureRule`s the existing `PolicyEngine` already enforces, so the
// deterministic egress decision stays in one place.

extension IssueKey {
    /// Who is coming: the confirmed people of a plan (ADR 0012).
    public static let people = IssueKey(known: "people")
    /// Photos offered in a matched exchange (Swap photos).
    public static let photos = IssueKey(known: "photos")
    /// Standing interests, as keywords, beyond the current activity.
    public static let interests = IssueKey(known: "interests")
}

/// One thing the owner can choose to share, ask about, or never share.
public enum PrivacyTopic: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case time, activity, place, budget, diet, people, photos, interests

    /// Time and activity are always shared as the overlap: nothing can line
    /// up without them, so they offer Share and Ask me but never Never.
    public var allowsNever: Bool { self != .time && self != .activity }

    /// The issues this topic covers. Every issue belongs to exactly one topic.
    public var issues: Set<IssueKey> {
        switch self {
        case .time: [.time]
        case .activity: [.activity, .downLevel]
        case .place: [.place]
        case .budget: [.budget]
        case .diet: [.diet]
        case .people: [.people, .partySize]
        case .photos: [.photos]
        case .interests: [.interests]
        }
    }

    /// The topic an issue belongs to, or nil for an issue no topic names.
    /// An issue without a topic falls back to the policy's default (ask).
    public init?(issue: IssueKey) {
        guard let topic = Self.allCases.first(where: { $0.issues.contains(issue) }) else { return nil }
        self = topic
    }

    public static func < (lhs: PrivacyTopic, rhs: PrivacyTopic) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// The owner's choice for one topic: Share / Ask me / Never.
public enum SharingChoice: String, Hashable, Sendable, Codable, CaseIterable {
    /// Send without asking to paired peers whose agent runs on their own
    /// device. A peer whose model runs elsewhere still gets a consent sheet
    /// (App Review 5.1.2(i), ADR 0014).
    case share
    /// Show a consent sheet for every exchange that includes the topic.
    case askMe
    /// Never send any value for the topic. Not offered for time or activity.
    case never

    /// The policy action this choice maps to.
    public var action: DisclosureRule.Action {
        switch self {
        case .share: .allowOnDevicePeers
        case .askMe: .askEachTime
        case .never: .never
        }
    }
}

/// One choice per topic. Topics the owner has not set use `defaultChoice`.
/// Stored on the device only; no `MessageBody` case can carry it.
public struct PrivacySettings: Hashable, Sendable, Codable {
    public private(set) var choices: [PrivacyTopic: SharingChoice]

    /// Time and activity default to Share because they leave only as the
    /// overlap; every other topic defaults to Ask me.
    public static func defaultChoice(for topic: PrivacyTopic) -> SharingChoice {
        topic.allowsNever ? .askMe : .share
    }

    public static let defaults = PrivacySettings()

    public init() { choices = [:] }

    public init(_ choices: [PrivacyTopic: SharingChoice]) throws {
        for (topic, choice) in choices where choice == .never && !topic.allowsNever {
            throw ValidationError("PrivacySettings.\(topic.rawValue)", "cannot be never: it is shared only as the overlap")
        }
        self.choices = choices
    }

    public func choice(for topic: PrivacyTopic) -> SharingChoice {
        choices[topic] ?? Self.defaultChoice(for: topic)
    }

    /// Sets one topic. Throws for Never on time or activity.
    public mutating func set(_ choice: SharingChoice, for topic: PrivacyTopic) throws {
        guard choice != .never || topic.allowsNever else {
            throw ValidationError("PrivacySettings.\(topic.rawValue)", "cannot be never: it is shared only as the overlap")
        }
        choices[topic] = choice
    }

    /// The topics set to Never.
    public var neverTopics: Set<PrivacyTopic> {
        Set(PrivacyTopic.allCases.filter { choice(for: $0) == .never })
    }

    /// One `DisclosureRule` per issue of every topic, for `OwnerRules`. The
    /// policy engine then applies them exactly as it applies Phase 1 rules.
    public var disclosureRules: [DisclosureRule] {
        PrivacyTopic.allCases.flatMap { topic in
            topic.issues.sorted().map { DisclosureRule(issue: $0, action: choice(for: topic).action) }
        }
    }

    private enum CodingKeys: String, CodingKey { case choices }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(c.decode([PrivacyTopic: SharingChoice].self, forKey: .choices))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(choices, forKey: .choices)
    }
}

extension PrivacyTopic: CodingKeyRepresentable {}
