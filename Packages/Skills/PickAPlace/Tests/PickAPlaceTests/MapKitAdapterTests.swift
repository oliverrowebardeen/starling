import CoreLocation
import Foundation
import MapKit
import PickAPlace
@testable import PickAPlaceMapKit
import StarlingCore
import Testing

@Suite("MapKit adapter")
struct MapKitAdapterTests {
    @Test(arguments: [
        (MKPointOfInterestCategory.restaurant, "restaurant"),
        (.foodMarket, "food market"),
        (.cafe, "cafe"),
        (.nightlife, "nightlife"),
        (.atm, "atm"),
    ])
    func categoriesBecomeKinds(category: MKPointOfInterestCategory, kind: String) {
        #expect(MapKitPlaceSearch.kind(of: category) == kw(kind))
    }

    @Test func mapsNamesAreCleanedAndClipped() throws {
        #expect(MapKitPlaceSearch.displayName("Boba\nGuys")?.rawValue == "Boba Guys")
        #expect(MapKitPlaceSearch.displayName(String(repeating: "x", count: 100))?.rawValue.count == ProtocolLimits.maxPlaceNameCharacters)
        #expect(MapKitPlaceSearch.displayName("   ") == nil)
        #expect(MapKitPlaceSearch.displayName(nil) == nil)
    }

    @Test func aMapItemBecomesACandidateWithHonestFacts() throws {
        let item = MKMapItem(location: CLLocation(latitude: 37.77926, longitude: -122.41935), address: nil)
        item.name = "Boba Guys"
        item.pointOfInterestCategory = .cafe
        let candidate = try #require(MapKitPlaceSearch.candidate(item))
        #expect(candidate.choice.name.rawValue == "Boba Guys")
        #expect(candidate.choice.coordinate == (try Coordinate(latitude: 37.77926, longitude: -122.41935)))
        #expect(candidate.facts.kinds == [kw("cafe")])
        // Apple Maps has no price or diet data; unknown, not guessed.
        #expect(candidate.facts.priceTier == nil)
        #expect(candidate.facts.diets == nil)
    }

    @Test func aVenueWithoutAnIdentifierHasNoFactsToLookUp() async throws {
        #expect(try await MapKitPlaceSearch().facts(for: place("Grandma's Kitchen")) == nil)
    }

    @MainActor @Test func authorizationMapsToThreeOutcomes() {
        #expect(CoreLocationAccess.map(.notDetermined) == .notDetermined)
        #expect(CoreLocationAccess.map(.denied) == .denied)
        #expect(CoreLocationAccess.map(.restricted) == .restricted)
        // `.authorizedWhenInUse` exists only on iOS; Always covers it too.
        #expect(CoreLocationAccess.map(.authorizedAlways) == .whenInUse)
    }

    /// Hits Apple Maps over the network: opt-in with STARLING_MAPKIT_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["STARLING_MAPKIT_TESTS"] == "1"))
    func liveSearchNearATypedAreaNeedsNoLocation() async throws {
        let search = MapKitPlaceSearch()
        let found = try await search.search("coffee", in: .named("Union Square, San Francisco"), limit: 8)
        #expect(!found.isEmpty)
        #expect(found.count <= 8)
        let first = try #require(found.first { $0.choice.mapItemID != nil })
        let facts = try await search.facts(for: first.choice)
        #expect(facts?.name == first.choice.name)
        print("live:", found.map { "\($0.choice.name) \($0.choice.mapItemID ?? "-") \($0.facts.kinds)" })
    }
}
