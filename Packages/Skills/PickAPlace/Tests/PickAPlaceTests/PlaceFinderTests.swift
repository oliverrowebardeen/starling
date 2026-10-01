import PickAPlace
import StarlingCore
import Testing

@Suite("Finding candidates")
struct PlaceFinderTests {
    let venues = [
        candidate("Boba Guys", id: "I1", tier: .one, kinds: ["boba"]),
        candidate("Tea Lab", id: "I2", tier: .one, kinds: ["boba"]),
    ]

    @Test func aTypedAreaNeedsNoLocation() async throws {
        let maps = FakeMaps(venues)
        let location = FakeLocation(.denied)
        let result = await PlaceFinder(search: maps, location: location).find("boba", near: .named("Franklin St"))
        #expect(result == .found(venues))
        #expect(await location.alertsShown == 0)
        #expect(await location.positionReads == 0)
        let search = try #require(await maps.searches.first)
        #expect(search.what == "boba")
        #expect(search.region == .named("Franklin St"))
    }

    @Test func nearbyNeverShowsTheSystemAlertByItself() async {
        let location = FakeLocation(.notDetermined)
        let result = await PlaceFinder(search: FakeMaps(venues), location: location).find("boba", near: .nearby)
        #expect(result == .needsLocationPermission)
        #expect(await location.alertsShown == 0)
    }

    @Test func continueOnStarlingsSheetAsksThenSearchesNearby() async throws {
        let maps = FakeMaps(venues)
        let location = FakeLocation(.notDetermined, answersAlertWith: .whenInUse)
        let result = await PlaceFinder(search: maps, location: location, radiusMeters: 1_000).allowLocationAndFind("boba")
        #expect(result == .found(venues))
        #expect(await location.alertsShown == 1)
        let search = try #require(await maps.searches.first)
        #expect(search.region == .around(try Coordinate(latitude: 37.7793, longitude: -122.4193), radiusMeters: 1_000))
    }

    @Test func dontAllowFallsBackToManualEntry() async {
        let maps = FakeMaps(venues)
        let location = FakeLocation(.notDetermined, answersAlertWith: .denied)
        let finder = PlaceFinder(search: maps, location: location)
        #expect(await finder.allowLocationAndFind("boba") == .manualEntry(.locationDenied))
        // Asked once; afterwards nearby goes straight to manual entry.
        #expect(await finder.find("boba", near: .nearby) == .manualEntry(.locationDenied))
        #expect(await location.alertsShown == 1)
        #expect(await maps.searches.isEmpty)
    }

    @Test func restrictedIsTreatedLikeDenied() async {
        let finder = PlaceFinder(search: FakeMaps(venues), location: FakeLocation(.restricted))
        #expect(await finder.find("boba", near: .nearby) == .manualEntry(.locationDenied))
    }

    @Test func noPositionFallsBackToManualEntry() async {
        let finder = PlaceFinder(search: FakeMaps(venues), location: FakeLocation(.whenInUse, here: nil))
        #expect(await finder.find("boba", near: .nearby) == .manualEntry(.locationUnavailable))
    }

    @Test func noResultsOrAFailedSearchFallBackToManualEntry() async {
        #expect(await PlaceFinder(search: FakeMaps([]), location: FakeLocation(.denied)).find("boba", near: .named("x")) == .manualEntry(.noResults))
        let failing = FakeMaps(venues)
        await failing.setFailSearches(true)
        #expect(await PlaceFinder(search: failing, location: FakeLocation(.denied)).find("boba", near: .named("x")) == .manualEntry(.searchFailed))
    }

    @Test func resultsAreDeduplicatedAndCapped() async {
        let many = (0..<12).map { candidate("Place \($0)", id: "P\($0)") }
        let result = await PlaceFinder(search: FakeMaps(many + many), location: FakeLocation(.denied)).find("food", near: .named("x"))
        guard case .found(let found) = result else { Issue.record("expected results"); return }
        #expect(found.count == ProtocolLimits.maxPlacesPerValue)
        #expect(Set(found.map(\.choice)).count == found.count)
    }

    @Test func aManualPlaceHasNoIdentifierAndUnknownFacts() throws {
        let typed = try PlaceCandidate.manual("  Grandma's kitchen ")
        #expect(typed.choice.name.rawValue == "Grandma's kitchen")
        #expect(typed.choice.mapItemID == nil)
        #expect(typed.facts.priceTier == nil && typed.facts.diets == nil)
        #expect(throws: ValidationError.self) { try PlaceCandidate.manual("line\nbreak") }
    }

    @Test func purposeStringAndSheetReadAsPlans() {
        #expect(!PickAPlaceSkill.locationPurpose.isEmpty)
        #expect(PickAPlaceSkill.locationSheet.continueAction == "Continue")
        let words = [PickAPlaceSkill.locationPurpose, PickAPlaceSkill.locationSheet.deniedNote]
        #expect(words.allSatisfy { !$0.contains("\u{2014}") })
    }
}
