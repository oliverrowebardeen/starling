import Foundation
import PickAPlace
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

struct FakePlaces: PlaceSearching {
    let found: [PlaceCandidate]
    func search(_ what: String, in region: SearchRegion, limit: Int) async throws -> [PlaceCandidate] { Array(found.prefix(limit)) }
    func facts(for place: PlaceChoice) async throws -> PlaceFacts? { nil }
}

actor FakeLocation: LocationAccess {
    private var current: LocationAuthorization
    private let answer: LocationAuthorization
    private(set) var requests = 0
    init(_ current: LocationAuthorization, answer: LocationAuthorization = .whenInUse) {
        self.current = current
        self.answer = answer
    }
    func authorization() async -> LocationAuthorization { current }
    func requestWhenInUse() async -> LocationAuthorization {
        requests += 1
        current = answer
        return answer
    }
    func currentCoordinate() async throws -> Coordinate { try Coordinate(latitude: 37.77, longitude: -122.42) }
}

@MainActor
@Suite struct PlacePickerTests {
    static func candidate(_ name: String, tier: PriceTier? = nil) throws -> PlaceCandidate {
        PlaceCandidate(choice: try PlaceChoice(name: PlaceName(name), mapItemID: "I\(name.filter(\.isLetter))"), facts: PlaceFacts(priceTier: tier))
    }

    func settings() async -> SettingsModel {
        let model = SettingsModel(store: InMemoryOwnerSettingsStore(), flags: .phase1_5)
        await model.load()
        return model
    }

    @Test func aNamedAreaSearchPicksTheFirstFew() async throws {
        let found = try (1...6).map { try Self.candidate("Place \(["A", "B", "C", "D", "E", "F"][$0 - 1])") }
        let location = FakeLocation(.notDetermined)
        let gate = PermissionGate(access: [LocationPermissionAccess(location: location)])
        let picker = PlacePicker(finder: PlaceFinder(search: FakePlaces(found: found), location: location), staging: StagedCandidates())
        picker.what = "dinner"
        picker.area = "near Franklin"
        await picker.search(permissions: gate, skill: PickAPlaceSkill.descriptor, friends: ["Maya"], settings: await settings())
        #expect(picker.status == .found)
        #expect(picker.chosen.map(\.choice) == found.prefix(4).map(\.choice))
        #expect(await location.requests == 0, "a typed area needs no location")
        #expect(gate.pending == nil)
    }

    /// ADR 0013 and P15-D request 1: Nearby the first time shows Starling's
    /// sheet, and the system alert only after Continue.
    @Test func nearbyAsksThroughStarlingsSheetFirst() async throws {
        let found = [try Self.candidate("Boba Guys")]
        let location = FakeLocation(.notDetermined)
        let gate = PermissionGate(access: [LocationPermissionAccess(location: location)])
        let picker = PlacePicker(finder: PlaceFinder(search: FakePlaces(found: found), location: location), staging: StagedCandidates())
        picker.what = "boba"
        picker.nearby = true
        let settings = await settings()
        let searching = Task { await picker.search(permissions: gate, skill: PickAPlaceSkill.descriptor, friends: ["Maya"], settings: settings) }
        await eventually { gate.pending != nil }
        #expect(gate.pending?.title == PickAPlaceSkill.locationSheet.title)
        #expect(gate.pending?.rows.last == DisplayLine(title: "Maya sees", detail: PickAPlaceSkill.locationSheet.friendsSee))
        #expect(await location.requests == 0)
        gate.proceed()
        await searching.value
        #expect(await location.requests == 1)
        #expect(picker.chosen.map(\.choice) == found.map(\.choice))
    }

    @Test func aDenialLeavesTheOwnerTypingPlaces() async throws {
        let location = FakeLocation(.notDetermined, answer: .denied)
        let gate = PermissionGate(access: [LocationPermissionAccess(location: location)])
        let picker = PlacePicker(finder: PlaceFinder(search: FakePlaces(found: []), location: location), staging: StagedCandidates())
        picker.what = "boba"
        picker.nearby = true
        let settings = await settings()
        let searching = Task { await picker.search(permissions: gate, skill: PickAPlaceSkill.descriptor, friends: [], settings: settings) }
        await eventually { gate.pending != nil }
        gate.proceed()
        await searching.value
        #expect(picker.status == .manualEntry(.locationDenied))
        #expect(picker.notice == PickAPlaceSkill.locationSheet.deniedNote)
        #expect(picker.add("Boba Guys"))
        #expect(!picker.add("Boba Guys"), "once")
        #expect(!picker.add(""))
        #expect(picker.chosen.map(\.choice.name.rawValue) == ["Boba Guys"])
    }

    /// P15-D request 2: Start stays off until some chosen place fits the
    /// owner's limits, and the reviewed places are staged before start.
    @Test func newStagesThePlacesTheOwnerReviewed() async throws {
        let h = try await ComposerHarness(skillModel: nil)
        let staging = StagedCandidates()
        let found = [try Self.candidate("Cheap Eats", tier: .one), try Self.candidate("Fancy", tier: .four)]
        let location = FakeLocation(.whenInUse)
        let picker = PlacePicker(finder: PlaceFinder(search: FakePlaces(found: found), location: location), staging: staging)
        let pick = ScriptedSkillService(descriptor: PickAPlaceSkill.descriptor)
        let registry = try SkillRegistry([SampleSkills.downFor, PickAPlaceSkill.descriptor])
        let lifecycle = LifecycleCoordinator(registry: registry, services: [pick], store: InMemoryInteractionStore(), now: h.clock.closure)
        let model = ComposerModel(skillModel: nil, lifecycle: lifecycle, settings: h.settings, cards: h.cards, permissions: h.permissions,
                                  friends: { [h] in h.friends }, savedRules: { nil }, localPeer: h.me, places: picker, now: h.clock.closure)
        try h.give(h.maya.id, [PickAPlaceSkill.descriptor.ref])
        await model.choose(.pickAPlace)
        model.audience = .pick
        model.picked = [h.maya.id]
        #expect(model.blocker == "Find a few places, or type one.")

        picker.what = "dinner"
        picker.area = "near Franklin"
        await picker.search(permissions: h.permissions, skill: PickAPlaceSkill.descriptor, friends: [], settings: h.settings)
        model.constraints = try ConstraintSet([.budget: [try Constraint(.atMost(try MoneyAmount(minorUnits: 100)))]])
        picker.selected = [found[1].choice]
        #expect(model.blocker == "None of these fit your limits.")
        picker.selected = [found[0].choice, found[1].choice]
        #expect(model.blocker == nil)

        let id = try #require(await model.send())
        let request = try #require(await pick.started.first)
        #expect(request.interaction == id)
        #expect(try await staging.candidates(for: request).map(\.choice) == [found[0].choice, found[1].choice])
        #expect(picker.chosen.isEmpty, "the draft is cleared")
    }
}
