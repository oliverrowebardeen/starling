import Foundation
import StarlingCore

// Finding candidate venues in Compose (ADR 0232). Search sits behind
// `PlaceSearching` and the owner's position behind `LocationAccess`, so
// every path, including a denied permission, is tested with fakes.
// `PickAPlaceMapKit` implements both for the app.

/// Where to search, as the search provider needs it.
public enum SearchRegion: Hashable, Sendable {
    /// An area in the owner's words ("Franklin St", "downtown San Jose").
    /// Needs no location permission.
    case named(String)
    /// Around a point, only ever the owner's own position on this phone.
    case around(Coordinate, radiusMeters: Double)
}

public protocol PlaceSearching: Sendable {
    /// Venues matching `what` ("dinner", "boba") in `region`, best first,
    /// with what the provider knows about each. At most `limit`.
    func search(_ what: String, in region: SearchRegion, limit: Int) async throws -> [PlaceCandidate]
    /// What this phone's provider knows about a venue a friend suggested,
    /// looked up by its Maps identifier. Nil when the venue has none or the
    /// provider does not know it. Never uses anything else the friend sent.
    func facts(for place: PlaceChoice) async throws -> PlaceFacts?
}

/// Location When In Use, as Pick a place sees it.
public enum LocationAuthorization: Hashable, Sendable {
    case notDetermined, denied, restricted, whenInUse
}

public protocol LocationAccess: Sendable {
    func authorization() async -> LocationAuthorization
    /// Shows the system alert and returns the owner's choice. Call it only
    /// from the Continue button of Starling's sheet (`PickAPlaceSkill.locationSheet`),
    /// the first time the owner asks for nearby places, never at launch
    /// (ADR 0013).
    func requestWhenInUse() async -> LocationAuthorization
    /// The owner's position, used only on this phone as the center of a
    /// search. It is never sent: candidates carry venues' coordinates only.
    func currentCoordinate() async throws -> Coordinate
}

/// Where the owner wants to look.
public enum PlaceArea: Hashable, Sendable {
    /// An area the owner typed. Works with location denied.
    case named(String)
    /// Near the owner. Needs Location When In Use.
    case nearby
}

/// Why Compose falls back to the owner typing places.
public enum ManualEntryReason: Hashable, Sendable {
    case locationDenied
    case locationUnavailable
    case noResults
    case searchFailed
}

public enum PlaceSearchResult: Hashable, Sendable {
    case found([PlaceCandidate])
    /// Nearby needs location and the owner has not been asked yet: show
    /// Starling's sheet, and on Continue call `PlaceFinder.allowLocationAndFind`.
    case needsLocationPermission
    /// Let the owner type a place (`PlaceCandidate.manual`) or an area.
    case manualEntry(ManualEntryReason)
}

/// Finds candidates for Compose. Never asks for a permission by itself:
/// it reports `needsLocationPermission`, and the app shows Starling's sheet
/// first (ADR 0013).
public struct PlaceFinder: Sendable {
    let search: any PlaceSearching
    let location: any LocationAccess
    let radiusMeters: Double

    public init(search: any PlaceSearching, location: any LocationAccess, radiusMeters: Double = 2_000) {
        self.search = search
        self.location = location
        self.radiusMeters = radiusMeters
    }

    public func find(_ what: String, near area: PlaceArea) async -> PlaceSearchResult {
        switch area {
        case .named(let name):
            return await run(what, in: .named(name))
        case .nearby:
            switch await location.authorization() {
            case .notDetermined: return .needsLocationPermission
            case .denied, .restricted: return .manualEntry(.locationDenied)
            case .whenInUse: return await nearby(what)
            }
        }
    }

    /// After Continue on Starling's sheet: the system alert, then a nearby
    /// search, or manual entry if the owner chose Don't Allow.
    public func allowLocationAndFind(_ what: String) async -> PlaceSearchResult {
        switch await location.requestWhenInUse() {
        case .whenInUse: await nearby(what)
        case .denied, .restricted, .notDetermined: .manualEntry(.locationDenied)
        }
    }

    private func nearby(_ what: String) async -> PlaceSearchResult {
        guard let here = try? await location.currentCoordinate() else { return .manualEntry(.locationUnavailable) }
        return await run(what, in: .around(here, radiusMeters: radiusMeters))
    }

    private func run(_ what: String, in region: SearchRegion) async -> PlaceSearchResult {
        do {
            var seen: Set<PlaceChoice> = []
            let found = try await search.search(what, in: region, limit: ProtocolLimits.maxPlacesPerValue)
                .filter { seen.insert($0.choice).inserted }
                .prefix(ProtocolLimits.maxPlacesPerValue)
            return found.isEmpty ? .manualEntry(.noResults) : .found(Array(found))
        } catch {
            return .manualEntry(.searchFailed)
        }
    }
}
