import Foundation
import Observation
import StarlingCore

/// What the owner chose in You and Friends, kept on the phone only: privacy
/// topics (ADR 0014), skill switches and "Just ask me" (ADR 0013), close
/// friends, and which first-use explanations they have seen. No
/// `MessageBody` can carry any of it.
public struct OwnerSettings: Hashable, Sendable, Codable {
    public var privacy = PrivacySettings.defaults
    /// Skills switched off in You.
    public var turnedOff: Set<SkillID> = []
    /// Skills told to ask the owner instead of using their permission
    /// ("Just ask me" for Find a time, typing a place for Pick a place).
    public var askInstead: Set<SkillID> = []
    /// The owner's own close friends list, for New's Ask picker.
    public var closeFriends: Set<PeerID> = []
    /// Refuse to negotiate with agents whose model does not run on their
    /// own phone (You, "Your agent").
    public var onlyOnDeviceAgents = false
    /// Whether Starling has done the deliberate Local Network prompt (at the
    /// first Pair or first request, ADR 0202). After that, links start at
    /// launch.
    public var localNetworkAsked = false
    /// Whether Starling has offered notifications (at the first request).
    public var notificationsOffered = false
    /// Permissions whose pre-permission sheet the owner has seen.
    public var permissionsExplained: Set<SystemPermission> = []

    public init() {}

    public static let defaults = OwnerSettings()

    /// Phase 1 kept sharing as per-issue rules in the saved rules. The first
    /// time Phase 1.5 runs, each topic takes the most restrictive rule saved
    /// for any of its issues, so an owner's "never share" is never loosened
    /// by the move to topics. Time and activity cannot be Never; a Phase 1
    /// "never" there becomes Ask me.
    public static func migrating(phaseOneSharing rules: [DisclosureRule]) -> OwnerSettings {
        var settings = OwnerSettings()
        for topic in PrivacyTopic.allCases {
            let actions = rules.filter { topic.issues.contains($0.issue) }.map(\.action)
            guard let first = actions.first else { continue }
            let strictest = actions.dropFirst().reduce(first) { RulesMerge.restrictive($0, $1) }
            let choice: SharingChoice = switch strictest {
            case .never: topic.allowsNever ? .never : .askMe
            case .askEachTime: .askMe
            case .allowOnDevicePeers: .share
            }
            try? settings.privacy.set(choice, for: topic)
        }
        return settings
    }

    private enum CodingKeys: String, CodingKey {
        case privacy, turnedOff, askInstead, closeFriends, onlyOnDeviceAgents, localNetworkAsked, notificationsOffered, permissionsExplained
    }

    /// Every key is optional on decode, so a later build can add one.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        privacy = try c.decodeIfPresent(PrivacySettings.self, forKey: .privacy) ?? .defaults
        turnedOff = try c.decodeIfPresent(Set<SkillID>.self, forKey: .turnedOff) ?? []
        askInstead = try c.decodeIfPresent(Set<SkillID>.self, forKey: .askInstead) ?? []
        closeFriends = try c.decodeIfPresent(Set<PeerID>.self, forKey: .closeFriends) ?? []
        onlyOnDeviceAgents = try c.decodeIfPresent(Bool.self, forKey: .onlyOnDeviceAgents) ?? false
        localNetworkAsked = try c.decodeIfPresent(Bool.self, forKey: .localNetworkAsked) ?? false
        notificationsOffered = try c.decodeIfPresent(Bool.self, forKey: .notificationsOffered) ?? false
        permissionsExplained = try c.decodeIfPresent(Set<SystemPermission>.self, forKey: .permissionsExplained) ?? []
    }
}

public protocol OwnerSettingsStore: Sendable {
    func load() async throws -> OwnerSettings?
    func save(_ settings: OwnerSettings) async throws
}

/// `Application Support/Starling/settings.json` (ADR 0200's file helper).
public actor FileOwnerSettingsStore: OwnerSettingsStore {
    private let file: JSONFile

    public init(file: JSONFile) {
        self.file = file
    }

    public static func standard() throws -> FileOwnerSettingsStore {
        FileOwnerSettingsStore(file: try .standard("settings.json"))
    }

    public func load() async throws -> OwnerSettings? { try file.read(OwnerSettings.self) }
    public func save(_ settings: OwnerSettings) async throws { try file.write(settings) }
}

public actor InMemoryOwnerSettingsStore: OwnerSettingsStore {
    public private(set) var saved: OwnerSettings?

    public init(_ saved: OwnerSettings? = nil) {
        self.saved = saved
    }

    public func load() async throws -> OwnerSettings? { saved }
    public func save(_ settings: OwnerSettings) async throws { saved = settings }
}

/// The owner's settings as the screens use them. Every change is saved at
/// once and reported through `onChange`, which the app uses to rebuild the
/// policy and the agent card.
@MainActor
@Observable
public final class SettingsModel {
    public private(set) var settings = OwnerSettings.defaults
    public private(set) var isLoaded = false
    public private(set) var notice: String?
    /// True when a saved file exists but could not be read. Topics then
    /// stay at their defaults (Ask me, never looser), and nothing is
    /// written over the file until the owner changes a setting.
    public private(set) var loadFailed = false

    public let flags: SkillFlags
    public var onChange: @MainActor () async -> Void = {}

    private let store: any OwnerSettingsStore

    public init(store: any OwnerSettingsStore, flags: SkillFlags) {
        self.store = store
        self.flags = flags
    }

    public var skillSettings: SkillSettings {
        SkillSettings(flags: flags, turnedOff: settings.turnedOff, privacy: settings.privacy)
    }

    /// Loads the saved settings, or migrates Phase 1's sharing rules the
    /// first time (`OwnerSettings.migrating`).
    public func load(phaseOneSharing: [DisclosureRule] = []) async {
        do {
            if let saved = try await store.load() {
                settings = saved
            } else {
                settings = .migrating(phaseOneSharing: phaseOneSharing)
                try? await store.save(settings)
            }
            loadFailed = false
        } catch {
            settings = .defaults
            loadFailed = true
            notice = "Your privacy settings couldn't be read, so every topic asks you first until you change one."
        }
        isLoaded = true
    }

    public func choice(for topic: PrivacyTopic) -> SharingChoice { settings.privacy.choice(for: topic) }

    public func set(_ choice: SharingChoice, for topic: PrivacyTopic) async {
        await update { try $0.privacy.set(choice, for: topic) }
    }

    public func isOn(_ skill: SkillID) -> Bool { !settings.turnedOff.contains(skill) }

    public func setSkill(_ skill: SkillID, on: Bool) async {
        await update { if on { $0.turnedOff.remove(skill) } else { $0.turnedOff.insert(skill) } }
    }

    public func asksInstead(_ skill: SkillID) -> Bool { settings.askInstead.contains(skill) }

    public func setAskInstead(_ skill: SkillID, _ askInstead: Bool) async {
        await update { if askInstead { $0.askInstead.insert(skill) } else { $0.askInstead.remove(skill) } }
    }

    public func isClose(_ friend: PeerID) -> Bool { settings.closeFriends.contains(friend) }

    public func setClose(_ friend: PeerID, _ close: Bool) async {
        await update { if close { $0.closeFriends.insert(friend) } else { $0.closeFriends.remove(friend) } }
    }

    public func setOnlyOnDeviceAgents(_ on: Bool) async {
        await update { $0.onlyOnDeviceAgents = on }
    }

    public func markLocalNetworkAsked() async { await update { $0.localNetworkAsked = true } }
    public func markNotificationsOffered() async { await update { $0.notificationsOffered = true } }
    public func markExplained(_ permission: SystemPermission) async { await update { $0.permissionsExplained.insert(permission) } }

    /// Applies a change, saves it, then tells the app. A change that throws
    /// (Never on time or activity) is ignored.
    private func update(_ change: (inout OwnerSettings) throws -> Void) async {
        var next = settings
        do { try change(&next) } catch { return }
        guard next != settings else { return }
        settings = next
        do {
            try await store.save(next)
            loadFailed = false
            notice = nil
        } catch {
            notice = "Your settings couldn't be saved. They'll go back if Starling closes."
        }
        await onChange()
    }
}

/// The rules every send is judged by, and the rules a skill gets with each
/// request (ADR 0014 decision 7): the owner's saved constraints, with the
/// privacy topics as the only standing sharing. Phase 1's per-issue sharing
/// in the saved rules is migrated into topics once and then ignored.
public enum StandingRules {
    public static func standing(saved: OwnerRules?, privacy: PrivacySettings) -> OwnerRules {
        OwnerRules(constraints: saved?.constraints ?? .empty, disclosure: privacy.disclosureRules)
    }

    /// A request's chips merged with the standing rules: constraints
    /// accumulate with the intent's first, and the most restrictive sharing
    /// wins, so a request can never loosen a topic. Throws when the
    /// combined constraints break a limit.
    public static func forRequest(intent: ConstraintSet, saved: OwnerRules?, privacy: PrivacySettings) throws -> OwnerRules {
        try RulesMerge.intent(OwnerRules(constraints: intent), standing: standing(saved: saved, privacy: privacy))
    }
}
