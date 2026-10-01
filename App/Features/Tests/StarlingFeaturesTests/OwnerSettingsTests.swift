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
        settings.closeFriends = [.random()]
        settings.turnedOff = [.findATime]
        try await FileOwnerSettingsStore(file: file).save(settings)
        #expect(try await FileOwnerSettingsStore(file: file).load() == settings)
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
        #expect(model.choice(for: .budget) == .askMe)
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
