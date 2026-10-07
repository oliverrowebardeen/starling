import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

@MainActor
@Suite struct OwnerSettingsTests {
    @Test func phaseOneSharingMigratesToTheStrictestTopicChoice() {
        let settings = OwnerSettings.migrating(phaseOneSharing: [
            DisclosureRule(issue: .place, action: .never),
            DisclosureRule(issue: .budget, action: .allowOnDevicePeers),
            DisclosureRule(issue: .partySize, action: .allowOnDevicePeers),
            DisclosureRule(issue: .people, action: .askEachTime),
            DisclosureRule(issue: .time, action: .never),
            DisclosureRule(issue: .activity, action: .allowOnDevicePeers),
        ])
        #expect(settings.privacy.choice(for: .place) == .never)
        #expect(settings.privacy.choice(for: .budget) == .share)
        // party_size said share, people said ask: the stricter wins.
        #expect(settings.privacy.choice(for: .people) == .askMe)
        // Time cannot be Never, so a Phase 1 "never" becomes Ask me.
        #expect(settings.privacy.choice(for: .time) == .askMe)
        #expect(settings.privacy.choice(for: .activity) == .share)
        #expect(settings.privacy.choice(for: .diet) == .askMe)
    }

    @Test func settingsAreSavedAndReported() async throws {
        let store = InMemoryOwnerSettingsStore()
        let model = SettingsModel(store: store, flags: .phase1_5)
        var changes = 0
        model.onChange = { changes += 1 }
        await model.load()
        let maya = PeerID.random()

        await model.set(.never, for: .budget)
        await model.setSkill(.pickAPlace, on: false)
        await model.setClose(maya, true)
        await model.setAskInstead(.findATime, true)
        await model.setOnlyOnDeviceAgents(true)
        await model.markExplained(.calendarFullAccess)
        // Never on time is refused, and an unchanged value saves nothing.
        await model.set(.never, for: .time)
        await model.set(.never, for: .budget)

        #expect(changes == 6)
        let saved = try #require(await store.saved)
        #expect(saved == model.settings)
        #expect(saved.privacy.choice(for: .budget) == .never)
        #expect(saved.privacy.choice(for: .time) == .share)
        #expect(model.skillSettings.turnedOff == [.pickAPlace])
        #expect(model.isClose(maya))
        #expect(model.asksInstead(.findATime))
        #expect(saved.onlyOnDeviceAgents)
        #expect(saved.permissionsExplained == [.calendarFullAccess])
    }

    @Test func settingsRoundTripThroughTheFile() async throws {
        let file = JSONFile(url: FileManager.default.temporaryDirectory.appending(path: "starling-settings-\(UUID().uuidString).json"))
        var settings = OwnerSettings()
        try settings.privacy.set(.never, for: .diet)
        settings.audience = AudienceBook(closeFriends: [.random()], groups: [try FriendGroup(name: "Climbing", members: [.random()])], rules: [.random(): .quietOnly])
        settings.turnedOff = [.findATime]
        try await FileOwnerSettingsStore(file: file).save(settings)
        #expect(try await FileOwnerSettingsStore(file: file).load() == settings)
    }

    /// Before Core v2.1 close friends were stored on their own.
    @Test func aPhaseOneCloseFriendsListMovesIntoTheAudienceBook() throws {
        let maya = PeerID.random()
        let json = #"{"closeFriends":["\#(maya.hex)"]}"#
        let decoded = try JSONDecoder().decode(OwnerSettings.self, from: Data(json.utf8))
        #expect(decoded.audience.closeFriends == [maya])
    }

    @Test func groupsAndRulesAreKeptAndUnpairingForgetsAFriend() async throws {
        let store = InMemoryOwnerSettingsStore()
        let model = SettingsModel(store: store, flags: .phase1_5)
        await model.load()
        let maya = PeerID.random(), jake = PeerID.random()
        let climbing = try FriendGroup(name: "Climbing", members: [maya, jake])
        await model.saveGroup(climbing)
        await model.setRule(.quietOnly, for: maya)
        await model.setClose(maya, true)
        #expect(model.groups.map(\.name) == ["Climbing"])
        #expect(model.rule(for: maya) == .quietOnly)

        await model.forget(maya)
        #expect(model.groups.first?.members == [jake])
        #expect(model.rule(for: maya) == nil)
        #expect(!model.isClose(maya))
        #expect(await store.saved?.audience == model.audienceBook)

        await model.deleteGroup(climbing.id)
        #expect(model.groups.isEmpty)
    }

    @Test func anOlderFileWithFewerKeysStillLoads() throws {
        let decoded = try JSONDecoder().decode(OwnerSettings.self, from: Data(#"{"onlyOnDeviceAgents":true}"#.utf8))
        #expect(decoded.onlyOnDeviceAgents)
        #expect(decoded.privacy == .defaults)
    }

    /// Review of PR #54, finding 2: an unreadable file is never written
    /// over, first-use bookkeeping included, until the owner resets.
    @Test func anUnreadableFileIsKeptUntilTheOwnerResets() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "starling-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = JSONFile(url: directory.appending(path: "settings.json"))
        try Data("not json".utf8).write(to: file.url)
        let model = SettingsModel(store: FileOwnerSettingsStore(file: file), flags: .phase1_5)
        await model.load(phaseOneSharing: [DisclosureRule(issue: .budget, action: .allowOnDevicePeers)])
        #expect(model.loadFailed)
        // Defaults, never the Phase 1 rule: budget's default is Never (ADR 0019).
        #expect(model.choice(for: .budget) == .never)
        #expect(model.notice != nil)

        await model.markLocalNetworkAsked()
        await model.set(.share, for: .diet)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "not json")
        #expect(model.settings.localNetworkAsked, "kept in memory")
        #expect(model.loadFailed)

        await model.recover()
        #expect(!model.loadFailed)
        let reread = try await FileOwnerSettingsStore(file: file).load()
        #expect(reread == model.settings)
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).filter { $0.contains("unreadable") }
        #expect(aside.count == 1)
    }

    /// Re-review of PR #54, finding 2: recovery that fails or is cut short
    /// leaves the unreadable file in place, so the next launch stays
    /// blocked instead of starting on defaults.
    @Test func anInterruptedRecoveryStaysBlockedOnTheNextLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "starling-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = JSONFile(url: directory.appending(path: "settings.json"))
        try Data("not json".utf8).write(to: file.url)

        struct SaveFails: OwnerSettingsStore {
            struct Failure: Error {}
            let base: FileOwnerSettingsStore
            func load() async throws -> OwnerSettings? { try await base.load() }
            func save(_ settings: OwnerSettings) async throws { throw Failure() }
            func keepCopyAside() async throws { try await base.keepCopyAside() }
        }
        let failing = SettingsModel(store: SaveFails(base: FileOwnerSettingsStore(file: file)), flags: .phase1_5)
        await failing.load()
        await failing.recover()
        #expect(failing.loadFailed)
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "not json")

        // The app exits after the copy and before the save.
        try await FileOwnerSettingsStore(file: file).keepCopyAside()
        let relaunched = SettingsModel(store: FileOwnerSettingsStore(file: file), flags: .phase1_5)
        await relaunched.load()
        #expect(relaunched.loadFailed, "still blocked, never first-use defaults")
    }

    @Test func topicsAreTheOnlyStandingSharing() throws {
        var privacy = PrivacySettings.defaults
        try privacy.set(.never, for: .budget)
        let saved = OwnerRules(
            constraints: try ConstraintSet([.budget: [try Constraint(.atMost(try MoneyAmount(minorUnits: 1500)))]]),
            disclosure: [DisclosureRule(issue: .budget, action: .allowOnDevicePeers)]
        )
        let standing = StandingRules.standing(saved: saved, privacy: privacy)
        #expect(standing.constraints == saved.constraints)
        #expect(standing.disclosure == privacy.disclosureRules)
        #expect(standing.disclosure.contains(DisclosureRule(issue: .budget, action: .never)))

        let activity = try ConstraintSet([.activity: [try Constraint(.prefers(liked: [try Keyword("boba")], avoided: []))]])
        let request = try StandingRules.forRequest(intent: activity, saved: saved, privacy: privacy)
        #expect(request.constraints.constraints.keys.sorted() == [.activity, .budget])
        #expect(request.disclosure.contains(DisclosureRule(issue: .budget, action: .never)))
    }
}

/// A settings store whose saves can be held or made to fail.
actor GatedSettingsStore: OwnerSettingsStore {
    struct Failure: Error {}
    private(set) var saved: OwnerSettings?
    private var blocked = false
    private var failing = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { held.count }

    private var unreadable: Bool
    init(_ saved: OwnerSettings? = nil, unreadable: Bool = false) {
        self.saved = saved
        self.unreadable = unreadable
    }

    func block() { blocked = true }
    func release() {
        blocked = false
        held.forEach { $0.resume() }
        held = []
    }
    func failSaves(_ fail: Bool = true) { failing = fail }

    func load() async throws -> OwnerSettings? {
        if unreadable { throw Failure() }
        return saved
    }
    func save(_ settings: OwnerSettings) async throws {
        if blocked { await withCheckedContinuation { held.append($0) } }
        if failing { throw Failure() }
        saved = settings
        unreadable = false
    }
    func keepCopyAside() async throws {}
}

/// Final review of PR #54, finding 2: an audience edit is confirmed only
/// once it is saved, and a failed one changes nothing, now or after a
/// relaunch.
@MainActor
@Suite struct AudienceEditDurabilityTests {
    let maya = PeerID.random()
    let jake = PeerID.random()

    @Test func aFailedExclusionChangesNothingAndJakeIsStillAsked() async throws {
        let store = GatedSettingsStore()
        let model = SettingsModel(store: store, flags: .phase1_5)
        await model.load()
        await store.failSaves()

        #expect(await !model.setRule(.neverInclude, for: jake))
        #expect(model.rule(for: jake) == nil)
        #expect(model.audienceError != nil)

        let relaunched = SettingsModel(store: store, flags: .phase1_5)
        await relaunched.load()
        #expect(relaunched.rule(for: jake) == nil)
        let asked = Audience.allFriends.resolve(mode: .invite, friends: [maya, jake], book: relaunched.audienceBook, canRun: { _ in true })
        #expect(asked == [maya, jake], "the owner was told it failed, and nothing pretends otherwise")

        await store.failSaves(false)
        #expect(await model.setRule(.neverInclude, for: jake))
        #expect(model.audienceError == nil)
        let reloaded = SettingsModel(store: store, flags: .phase1_5)
        await reloaded.load()
        #expect(Audience.allFriends.resolve(mode: .invite, friends: [maya, jake], book: reloaded.audienceBook, canRun: { _ in true }) == [maya])
    }

    @Test func aFailedGroupEditKeepsTheSavedMembers() async throws {
        let store = GatedSettingsStore()
        let model = SettingsModel(store: store, flags: .phase1_5)
        await model.load()
        let group = try FriendGroup(name: "Climbing", members: [maya, jake])
        #expect(await model.saveGroup(group))
        await store.failSaves()
        #expect(await !model.saveGroup(try FriendGroup(id: group.id, name: "Climbing", members: [maya])))
        #expect(model.groups.first?.members == [maya, jake])
    }

    /// An edit is not shown until its save is done.
    @Test func anEditShowsOnlyAfterItsSaveIsDurable() async throws {
        let store = GatedSettingsStore()
        let model = SettingsModel(store: store, flags: .phase1_5)
        await model.load()
        await store.block()
        let editing = Task { await model.setRule(.neverInclude, for: jake) }
        await waitUntil { await store.waiting > 0 }
        #expect(model.rule(for: jake) == nil)
        await store.release()
        #expect(await editing.value)
        #expect(model.rule(for: jake) == .neverInclude)
    }

    /// Final review of PR #54: recovery and audience edits run one at a
    /// time, so an edit made while recovery saves is saved after it, never
    /// confirmed and then lost.
    @Test func recoveryAndAnAudienceEditRunOneAtATime() async throws {
        let store = GatedSettingsStore(unreadable: true)
        let model = SettingsModel(store: store, flags: .phase1_5)
        await model.load()
        #expect(model.loadFailed)
        await store.block()
        let recovering = Task { await model.recover() }
        await waitUntil { await store.waiting > 0 }
        let editing = Task { await model.setRule(.neverInclude, for: jake) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(model.rule(for: jake) == nil, "the edit waits for recovery")
        await store.release()
        await recovering.value
        #expect(await editing.value)
        #expect(!model.loadFailed)
        #expect(await store.saved?.audience.rules[jake] == .neverInclude, "saved durably, not only in memory")
    }

    @Test func aFailedLooseningGoesBackAndAFailedTighteningStays() async throws {
        let store = GatedSettingsStore()
        let model = SettingsModel(store: store, flags: .phase1_5)
        await model.load()
        await store.failSaves()
        await model.set(.share, for: .budget)
        #expect(model.choice(for: .budget) == .never, "loosening that did not save is not made")
        await model.set(.never, for: .place)
        #expect(model.choice(for: .place) == .never, "tightening applies until the app closes")
    }
}
