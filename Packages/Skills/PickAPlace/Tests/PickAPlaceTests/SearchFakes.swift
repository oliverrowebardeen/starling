import Foundation
import PickAPlace
import StarlingCore

/// Stands in for Apple Maps: one shared directory of venues, so every phone
/// looks up the same facts for an identifier, as with MapKit.
actor FakeMaps: PlaceSearching {
    private var venues: [PlaceCandidate]
    private(set) var searches: [(what: String, region: SearchRegion)] = []
    private(set) var lookups: [PlaceChoice] = []
    var failSearches = false

    init(_ venues: [PlaceCandidate] = []) { self.venues = venues }

    func add(_ venue: PlaceCandidate) { venues.append(venue) }
    /// What Maps now says about a venue, by its identifier.
    func update(_ venue: PlaceCandidate) {
        venues.removeAll { $0.choice.mapItemID == venue.choice.mapItemID }
        venues.append(venue)
    }
    func setFailSearches(_ fail: Bool) { failSearches = fail }

    func search(_ what: String, in region: SearchRegion, limit: Int) async throws -> [PlaceCandidate] {
        searches.append((what, region))
        if failSearches { throw URLError(.notConnectedToInternet) }
        return Array(venues.prefix(limit))
    }

    func facts(for place: PlaceChoice) async throws -> PlaceFacts? {
        lookups.append(place)
        guard let id = place.mapItemID else { return nil }
        return venues.first { $0.choice.mapItemID == id }?.facts
    }
}

/// Location When In Use, scripted. Records whether the system alert was shown.
actor FakeLocation: LocationAccess {
    private var status: LocationAuthorization
    private let answer: LocationAuthorization
    private let here: Coordinate?
    private(set) var alertsShown = 0
    private(set) var positionReads = 0

    init(_ status: LocationAuthorization, answersAlertWith answer: LocationAuthorization = .whenInUse, here: Coordinate? = try! Coordinate(latitude: 37.7793, longitude: -122.4193)) {
        self.status = status
        self.answer = answer
        self.here = here
    }

    func authorization() async -> LocationAuthorization { status }

    func requestWhenInUse() async -> LocationAuthorization {
        guard status == .notDetermined else { return status }
        alertsShown += 1
        status = answer
        return status
    }

    func currentCoordinate() async throws -> Coordinate {
        positionReads += 1
        guard status == .whenInUse, let here else { throw URLError(.cannotFindHost) }
        return here
    }
}
