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
    /// Close friends, saved groups, and per-friend rules (ADR 0020), for
    /// `Audience.resolve`. Kept on this phone only.
    public var audience = AudienceBook.empty
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
        case privacy, turnedOff, askInstead, audience, onlyOnDeviceAgents, localNetworkAsked, notificationsOffered, permissionsExplained
        /// Before Core v2.1 close friends were stored on their own.
        case closeFriends
    }

    /// Every key is optional on decode, so a later build can add one.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        privacy = try c.decodeIfPresent(PrivacySettings.self, forKey: .privacy) ?? .defaults
        turnedOff = try c.decodeIfPresent(Set<SkillID>.self, forKey: .turnedOff) ?? []
        askInstead = try c.decodeIfPresent(Set<SkillID>.self, forKey: .askInstead) ?? []
        audience = try c.decodeIfPresent(AudienceBook.self, forKey: .audience)
            ?? AudienceBook(closeFriends: c.decodeIfPresent(Set<PeerID>.self, forKey: .closeFriends) ?? [])
        onlyOnDeviceAgents = try c.decodeIfPresent(Bool.self, forKey: .onlyOnDeviceAgents) ?? false
        localNetworkAsked = try c.decodeIfPresent(Bool.self, forKey: .localNetworkAsked) ?? false
        notificationsOffered = try c.decodeIfPresent(Bool.self, forKey: .notificationsOffered) ?? false
        permissionsExplained = try c.decodeIfPresent(Set<SystemPermission>.self, forKey: .permissionsExplained) ?? []
    }

    /// What may leave the phone while a change is being saved: for each
    /// topic the stricter of `a` and `b`, and on-device only if either says
    /// so. Everything else comes from `b`.
    public static func strictest(_ a: OwnerSettings, _ b: OwnerSettings) -> OwnerSettings {
        var result = b
        for topic in PrivacyTopic.allCases {
            let choices = [a.privacy.choice(for: topic), b.privacy.choice(for: topic)]
            let order: [SharingChoice] = [.never, .askMe, .share]
            let strictest = choices.min { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! }!
            try? result.privacy.set(strictest, for: topic)
        }
        result.onlyOnDeviceAgents = a.onlyOnDeviceAgents || b.onlyOnDeviceAgents
        return result
    }

    /// Whether `next` lets anything out that `previous` did not.
    static func loosens(_ previous: OwnerSettings, to next: OwnerSettings) -> Bool {
        let interim = strictest(previous, next)
        // Compare the choice in effect for each topic: stored choices and
        // defaults are the same thing to the policy.
        let looserTopic = PrivacyTopic.allCases.contains { interim.privacy.choice(for: $0) != next.privacy.choice(for: $0) }
        return looserTopic || interim.onlyOnDeviceAgents != next.onlyOnDeviceAgents
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(privacy, forKey: .privacy)
        try c.encode(turnedOff, forKey: .turnedOff)
        try c.encode(askInstead, forKey: .askInstead)
        try c.encode(audience, forKey: .audience)
        try c.encode(onlyOnDeviceAgents, forKey: .onlyOnDeviceAgents)
        try c.encode(localNetworkAsked, forKey: .localNetworkAsked)
        try c.encode(notificationsOffered, forKey: .notificationsOffered)
        try c.encode(permissionsExplained, forKey: .permissionsExplained)
    }
}

public protocol OwnerSettingsStore: Sendable {
    func load() async throws -> OwnerSettings?
    func save(_ settings: OwnerSettings) async throws
    /// Keeps a copy of an unreadable file aside, leaving it in place until
    /// a save replaces it in one atomic write.
    func keepCopyAside() async throws
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
    public func keepCopyAside() async throws { try file.copyAside() }
}

public actor InMemoryOwnerSettingsStore: OwnerSettingsStore {
    public private(set) var saved: OwnerSettings?

    public init(_ saved: OwnerSettings? = nil) {
        self.saved = saved
    }

    public func load() async throws -> OwnerSettings? { saved }
    public func save(_ settings: OwnerSettings) async throws { saved = settings }
    public func keepCopyAside() async throws {}
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
    /// True when a saved file exists but could not be read. The file may
    /// hold a Never the app cannot see, so the app keeps every send blocked
    /// and nothing is written over the file until the owner resets their
    /// privacy settings explicitly with `recover()`. Changes meanwhile,
    /// first-use bookkeeping included, stay in memory.
    public private(set) var loadFailed = false

    public let flags: SkillFlags
    public var onChange: @MainActor () async -> Void = {}
    /// Called before a change is shown or saved, with what may leave the
    /// phone until the save is done: the stricter of the old and new
    /// settings. The app installs the policy for it, so a restrictive change
    /// governs sends at once (final review of PR #54, finding 1).
    public var beforeSave: @MainActor (_ interim: OwnerSettings) async -> Void = { _ in }
    /// Why the last audience edit (a rule, a group, close friends) did not
    /// save, for the editors to show. Nil once one saves.
    public private(set) var audienceError: String?
    private var isUpdating = false

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
            notice = "Your privacy settings couldn't be read, so Starling won't send anything until you check them and tap Use these settings."
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

    public var audienceBook: AudienceBook { settings.audience }

    public func isClose(_ friend: PeerID) -> Bool { settings.audience.closeFriends.contains(friend) }

    @discardableResult
    public func setClose(_ friend: PeerID, _ close: Bool) async -> Bool {
        await update(confirmFirst: true) { if close { $0.audience.closeFriends.insert(friend) } else { $0.audience.closeFriends.remove(friend) } }
    }

    /// The owner's saved groups, by name.
    public var groups: [FriendGroup] {
        settings.audience.groups.values.sorted { ($0.name.lowercased(), $0.id.description) < ($1.name.lowercased(), $1.id.description) }
    }

    /// Adds or replaces a group (matched by ID).
    /// Adds or replaces a group. Returns whether it was saved.
    @discardableResult
    public func saveGroup(_ group: FriendGroup) async -> Bool {
        await update(confirmFirst: true) { $0.audience.groups[group.id] = group }
    }

    @discardableResult
    public func deleteGroup(_ id: GroupID) async -> Bool {
        await update(confirmFirst: true) { $0.audience.groups[id] = nil }
    }

    public func rule(for friend: PeerID) -> FriendRule? { settings.audience.rules[friend] }

    /// Sets or clears a friend's standing rule. At most one per friend.
    @discardableResult
    public func setRule(_ rule: FriendRule?, for friend: PeerID) async -> Bool {
        await update(confirmFirst: true) { $0.audience.rules[friend] = rule }
    }

    /// Forgets an unpaired friend in every list and rule.
    @discardableResult
    public func forget(_ friend: PeerID) async -> Bool {
        await update(confirmFirst: true) { settings in
            settings.audience.closeFriends.remove(friend)
            settings.audience.rules[friend] = nil
            for (id, group) in settings.audience.groups where group.members.contains(friend) {
                settings.audience.groups[id] = try FriendGroup(id: id, name: group.name, members: group.members.subtracting([friend]))
            }
        }
    }

    public func setOnlyOnDeviceAgents(_ on: Bool) async {
        await update { $0.onlyOnDeviceAgents = on }
    }

    public func markLocalNetworkAsked() async { await update { $0.localNetworkAsked = true } }
    public func markNotificationsOffered() async { await update { $0.notificationsOffered = true } }
    public func markExplained(_ permission: SystemPermission) async { await update { $0.permissionsExplained.insert(permission) } }

    /// The owner checked the settings shown and chose to use them after the
    /// saved file could not be read: a copy of the unreadable file is kept
    /// aside, these settings replace it in one atomic write, and sends may
    /// go out again. The unreadable file stays in place until the write
    /// commits, so a failure or an exit midway leaves the next launch as
    /// blocked as this one, never on defaults (re-review of PR #54).
    public func recover() async {
        guard loadFailed else { return }
        do {
            try await store.keepCopyAside()
            try await store.save(settings)
        } catch {
            notice = "Your settings still couldn't be saved. Try again."
            return
        }
        loadFailed = false
        notice = nil
        await onChange()
    }

    /// Applies one change. Changes run one at a time, so none is computed
    /// from settings another is still saving.
    ///
    /// - `confirmFirst` (audience edits): saved first and shown only once
    ///   the save is durable. A failure changes nothing and sets
    ///   `audienceError` (final review of PR #54, finding 2).
    /// - Otherwise: `beforeSave` installs the stricter of the old and new
    ///   settings, the change is shown, then saved. A loosening that fails
    ///   to save goes back; a tightening stays in effect in memory.
    ///
    /// While the saved file is unreadable, changes stay in memory and
    /// nothing is written. A change that throws (Never on time or activity)
    /// is ignored. Returns whether the change took effect.
    @discardableResult
    private func update(confirmFirst: Bool = false, _ change: (inout OwnerSettings) throws -> Void) async -> Bool {
        while isUpdating { try? await Task.sleep(for: .milliseconds(5)) }
        isUpdating = true
        defer { isUpdating = false }
        var next = settings
        do { try change(&next) } catch { return false }
        guard next != settings else { return true }
        let previous = settings
        if loadFailed {
            settings = next
            await onChange()
            return true
        }
        if confirmFirst {
            do {
                try await store.save(next)
            } catch {
                audienceError = "That couldn't be saved, so nothing changed. Try again."
                return false
            }
            audienceError = nil
            settings = next
            await onChange()
            return true
        }
        await beforeSave(OwnerSettings.strictest(previous, next))
        settings = next
        var saved = true
        do {
            try await store.save(next)
            notice = nil
        } catch {
            saved = false
            if OwnerSettings.loosens(previous, to: next) {
                settings = previous
                notice = "That change couldn't be saved, so it wasn't made. Try again."
            } else {
                notice = "That change couldn't be saved. It applies until Starling closes."
            }
        }
        await onChange()
        return saved || !OwnerSettings.loosens(previous, to: next)
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
