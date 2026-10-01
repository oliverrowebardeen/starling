import Foundation
import StarlingCore
import Testing

@Suite struct SkillRegistryTests {
    static func registry() throws -> SkillRegistry {
        try SkillRegistry([
            SkillsTests.descriptor(.downFor, produces: [.plan]),
            SkillsTests.descriptor(.findATime, used: [.time], required: [.time], permissions: [.calendarFullAccess],
                                   produces: [.timeSlot, .plan], slots: [IntentSlot(.time, required: true, hint: "when")]),
            SkillsTests.descriptor(.pickAPlace, used: [.place, .budget, .diet], required: [.place], permissions: [.locationWhenInUse],
                                   accepts: [.plan], produces: [.placeChoice], slots: [IntentSlot(.place, required: false, hint: "where")]),
            SkillsTests.descriptor(.swapPhotos, used: [.photos], required: [.photos], permissions: [.photoLibrary],
                                   accepts: [.plan], produces: [], slots: [IntentSlot(.photos, required: false, hint: "which photos")]),
        ])
    }

    @Test func aSkillCanBeRegisteredOnce() throws {
        let down = try SkillsTests.descriptor()
        #expect(throws: ValidationError.self) { try SkillRegistry([down, down]) }
    }

    @Test func phaseOneFiveShipsThreeSkillsAndKeepsPhotosOff() throws {
        let registry = try Self.registry()
        let settings = SkillSettings(flags: .phase1_5)
        #expect(registry.inBuild(.phase1_5).map(\.id) == [.downFor, .findATime, .pickAPlace])
        #expect(registry.availability(of: .swapPhotos, in: settings) == .notInThisBuild)
        #expect(registry.availability(of: try SkillID("gift_pool"), in: settings) == .notInThisBuild)
        #expect(registry.advertised(in: settings).map(\.id) == [.downFor, .findATime, .pickAPlace])
    }

    @Test func ownerSwitchesAndPrivacyExplainWhyASkillCannotRun() throws {
        let registry = try Self.registry()
        var privacy = PrivacySettings.defaults
        try privacy.set(.never, for: .place)
        let settings = SkillSettings(flags: .phase1_5, turnedOff: [.findATime], privacy: privacy)
        #expect(registry.availability(of: .downFor, in: settings) == .available)
        #expect(registry.availability(of: .findATime, in: settings) == .turnedOff)
        #expect(registry.availability(of: .pickAPlace, in: settings) == .blockedByPrivacy([.place]))
        #expect(registry.available(in: settings).map(\.id) == [.downFor])
        // A privacy block stays on the card, so the card does not reveal it.
        #expect(registry.advertised(in: settings).map(\.id) == [.downFor, .pickAPlace])
    }

    @Test func chainSuggestionsNeedAnAcceptedArtifactAndEveryPeer() throws {
        let registry = try Self.registry()
        let everything = SkillSettings(flags: SkillFlags([.downFor, .findATime, .pickAPlace, .swapPhotos]))
        let full = try AgentCard(model: .onDevice, capabilities: [], skills: registry.advertised(in: everything))
        let noPhotos = try AgentCard(model: .onDevice, capabilities: [], skills: registry.advertised(in: SkillSettings(flags: .phase1_5)))

        #expect(registry.chainSuggestions(after: .downFor, in: everything, peers: [full]).map(\.id) == [.pickAPlace, .swapPhotos])
        // One friend without Swap photos hides it for the whole group.
        #expect(registry.chainSuggestions(after: .downFor, in: everything, peers: [full, noPhotos]).map(\.id) == [.pickAPlace])
        // Pick a place produces a PlaceChoice, which nothing in this set accepts.
        #expect(registry.chainSuggestions(after: .pickAPlace, in: everything, peers: [full]).isEmpty)
        // Flagged off locally: never suggested.
        #expect(registry.chainSuggestions(after: .downFor, in: SkillSettings(flags: .phase1_5), peers: [full]).map(\.id) == [.pickAPlace])
    }
}
