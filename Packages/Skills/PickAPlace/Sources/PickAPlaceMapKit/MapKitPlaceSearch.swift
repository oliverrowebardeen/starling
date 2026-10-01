import CoreLocation
import Foundation
import MapKit
import PickAPlace
import StarlingCore

/// Apple Maps search for Pick a place (ADR 0232).
///
/// Searching needs no location permission: the region comes from an area
/// the owner typed, or from the owner's own position only after Location
/// When In Use was granted. The owner's words go to Apple Maps, as any Maps
/// search does; nothing here reaches a friend.
///
/// Apple Maps gives a venue's name, identifier, coordinate, and category,
/// but no price level and no dietary information (`MKMapItem`), so the
/// facts it returns leave those unknown rather than guessing.
public struct MapKitPlaceSearch: PlaceSearching {
    public init() {}

    public func search(_ what: String, in region: SearchRegion, limit: Int) async throws -> [PlaceCandidate] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = what
        request.resultTypes = .pointOfInterest
        switch region {
        case .named(let area):
            guard let found = try await Self.region(named: area) else { return [] }
            request.region = found
        case .around(let center, let radiusMeters):
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
                latitudinalMeters: radiusMeters * 2, longitudinalMeters: radiusMeters * 2
            )
        }
        // A region is otherwise only a hint (MKLocalSearch.Request.region).
        request.regionPriority = .required
        let response = try await MKLocalSearch(request: request).start()
        return Array(response.mapItems.compactMap(Self.candidate).prefix(limit))
    }

    /// Looks a venue up by its Maps identifier. A friend's name for it and
    /// its coordinate are never used.
    public func facts(for place: PlaceChoice) async throws -> PlaceFacts? {
        guard let raw = place.mapItemID, let identifier = MKMapItem.Identifier(rawValue: raw) else { return nil }
        let item = try await MKMapItemRequest(mapItemIdentifier: identifier).mapItem
        return Self.facts(of: item)
    }

    /// The area the owner typed, as a region to search in.
    static func region(named area: String) async throws -> MKCoordinateRegion? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = area
        request.resultTypes = [.address, .pointOfInterest]
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.isEmpty ? nil : response.boundingRegion
    }

    static func candidate(_ item: MKMapItem) -> PlaceCandidate? {
        guard let name = displayName(item.name) else { return nil }
        let point = item.location.coordinate
        let coordinate = try? Coordinate(latitude: point.latitude, longitude: point.longitude)
        let identifier = item.identifier?.rawValue
        // An identifier that does not fit the wire's bounds is dropped, not
        // the venue.
        let choice = (try? PlaceChoice(name: name, coordinate: coordinate, mapItemID: identifier))
            ?? (try? PlaceChoice(name: name, coordinate: coordinate))
        return choice.map { PlaceCandidate(choice: $0, facts: facts(of: item, name: name)) }
    }

    static func facts(of item: MKMapItem, name: PlaceName? = nil) -> PlaceFacts {
        PlaceFacts(
            name: name ?? displayName(item.name),
            priceTier: nil,
            diets: nil,
            kinds: item.pointOfInterestCategory.flatMap(kind(of:)).map { [$0] } ?? []
        )
    }

    /// A Maps name as a `PlaceName`: line breaks and control characters
    /// removed, clipped to the wire's limit.
    static func displayName(_ raw: String?) -> PlaceName? {
        guard let raw else { return nil }
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
        let clipped = String(cleaned.trimmingCharacters(in: .whitespaces).prefix(ProtocolLimits.maxPlaceNameCharacters))
        return try? PlaceName(clipped)
    }

    /// "MKPOICategoryFoodMarket" becomes "food market".
    static func kind(of category: MKPointOfInterestCategory) -> Keyword? {
        let name = category.rawValue.hasPrefix("MKPOICategory") ? String(category.rawValue.dropFirst("MKPOICategory".count)) : category.rawValue
        var words = ""
        var previous: Character?
        for character in name {
            if character.isUppercase, let previous, previous.isLowercase { words.append(" ") }
            words.append(character)
            previous = character
        }
        return try? Keyword(words)
    }
}
