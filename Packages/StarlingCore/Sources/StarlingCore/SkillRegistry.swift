import Foundation

// The skill registry and feature flags (Phase 1.5, ADR 0010). The app
// registers every skill package's descriptor once; build flags decide which
// skills ship switched on, the owner can switch skills off in You, and
// privacy topics can block a skill. Everything here is pure so the rules are
// tested once and every screen agrees.

/// Which skills this build ships switched on. A flagged-off skill is not in
/// New, not in You, and not on the agent card.
public struct SkillFlags: Hashable, Sendable {
    public let enabled: Set<SkillID>

    public init(_ enabled: Set<SkillID>) { self.enabled = enabled }

    /// Phase 1.5 ships Down for…, Find a time, Pick a place, and Change the
    /// plan (ADR 0022), which runs only from a confirmed plan. Swap photos
    /// exists only far enough to prove the time-triggered chain hook.
    public static let phase1_5 = SkillFlags([.downFor, .findATime, .pickAPlace, .changePlan])
}

/// The owner's skill choices plus the build's flags: what decides whether a
/// skill can run right now.
public struct SkillSettings: Hashable, Sendable {
    public let flags: SkillFlags
    /// Skills the owner switched off in You.
    public let turnedOff: Set<SkillID>
    public let privacy: PrivacySettings

    public init(flags: SkillFlags, turnedOff: Set<SkillID> = [], privacy: PrivacySettings = .defaults) {
        self.flags = flags
        self.turnedOff = turnedOff
        self.privacy = privacy
    }
}

/// Whether a skill can run, and if not, why: each case has its own words in
/// the app, so a skill never fails silently.
public enum SkillAvailability: Hashable, Sendable {
    case available
    /// Flagged off, or no package registered it.
    case notInThisBuild
    /// The owner switched it off in You.
    case turnedOff
    /// Required topics set to Never ("Pick a place needs Place").
    case blockedByPrivacy(Set<PrivacyTopic>)

    public var isAvailable: Bool { self == .available }
}

public struct SkillRegistry: Sendable {
    /// In registration order, which is the order New and You show them.
    public let descriptors: [SkillDescriptor]

    public init(_ descriptors: [SkillDescriptor]) throws {
        guard Set(descriptors.map(\.id)).count == descriptors.count else {
            throw ValidationError("SkillRegistry", "a skill is registered twice")
        }
        self.descriptors = descriptors
    }

    public func descriptor(for id: SkillID) -> SkillDescriptor? {
        descriptors.first { $0.id == id }
    }

    public func availability(of id: SkillID, in settings: SkillSettings) -> SkillAvailability {
        guard let descriptor = descriptor(for: id), settings.flags.enabled.contains(id) else { return .notInThisBuild }
        guard !settings.turnedOff.contains(id) else { return .turnedOff }
        let blocking = descriptor.blockingTopics(in: settings.privacy)
        return blocking.isEmpty ? .available : .blockedByPrivacy(blocking)
    }

    /// The skills this build offers, for New's tiles and You's switches.
    public func inBuild(_ flags: SkillFlags) -> [SkillDescriptor] {
        descriptors.filter { flags.enabled.contains($0.id) }
    }

    /// The skills that can run now, for routing free text in New.
    public func available(in settings: SkillSettings) -> [SkillDescriptor] {
        descriptors.filter { availability(of: $0.id, in: settings).isAvailable }
    }

    /// What the agent card advertises: in this build and not switched off.
    /// A skill blocked only by privacy stays advertised and declines at
    /// request time, so the card never reveals the owner's privacy choices.
    public func advertised(in settings: SkillSettings) -> [SkillRef] {
        descriptors.filter { settings.flags.enabled.contains($0.id) && !settings.turnedOff.contains($0.id) }.map(\.ref)
    }

    /// "Keep it going" after `skill`: skills that accept what it produced,
    /// can run now, and every peer supports. Unsupported chains are hidden,
    /// not shown and failed (ADR 0012).
    public func chainSuggestions(after skill: SkillID, in settings: SkillSettings, peers: [AgentCard]) -> [SkillDescriptor] {
        guard let previous = descriptor(for: skill) else { return [] }
        return available(in: settings).filter { next in
            next.id != skill && next.canFollow(previous) && peers.allSatisfy { $0.support(for: next.ref).isSupported }
        }
    }
}
