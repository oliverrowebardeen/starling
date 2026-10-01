import Foundation
import StarlingCore

/// Typical spend per person, from "$" to "$$$$".
public enum PriceTier: Int, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case one = 1, two, three, four

    /// The low end of a typical spend per person at this tier, in US cents:
    /// $ under $15, $$ $15 to $30, $$$ $30 to $60, $$$$ over $60. A place
    /// breaks a budget only when even its low end is over it.
    public var typicalMinimumUSCents: Int64 {
        switch self {
        case .one: 0
        case .two: 1_500
        case .three: 3_000
        case .four: 6_000
        }
    }

    public var symbol: String { String(repeating: "$", count: rawValue) }

    public static func < (lhs: PriceTier, rhs: PriceTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What this phone knows about a venue. Every phone looks the facts up for
/// itself (`PlaceSearching.facts(for:)`); they are never sent and never
/// taken from a peer, so a friend cannot make a steakhouse look vegetarian
/// to your agent (ADR 0230).
public struct PlaceFacts: Hashable, Sendable {
    /// The venue's name as this phone's provider gives it, to check the name
    /// a friend sent for the same identifier.
    public let name: PlaceName?
    /// Nil when the provider does not know. MapKit never gives a price.
    public let priceTier: PriceTier?
    /// Diets the venue is known to serve ("vegetarian", "halal"), or nil when
    /// unknown. Empty means known to serve none of the ones it was asked about.
    public let diets: Set<Keyword>?
    /// What kind of place it is: categories and cuisines ("cafe", "boba").
    public let kinds: Set<Keyword>

    public init(name: PlaceName? = nil, priceTier: PriceTier? = nil, diets: Set<Keyword>? = nil, kinds: Set<Keyword> = []) {
        self.name = name
        self.priceTier = priceTier
        self.diets = diets
        self.kinds = kinds
    }

    public static let unknown = PlaceFacts()
}

/// A venue to ask friends about, with what this phone knows about it.
public struct PlaceCandidate: Hashable, Sendable {
    public let choice: PlaceChoice
    public let facts: PlaceFacts

    public init(choice: PlaceChoice, facts: PlaceFacts = .unknown) {
        self.choice = choice
        self.facts = facts
    }

    /// A place the owner typed because search could not run or found
    /// nothing (location denied, no results). It has no Maps identifier, so
    /// friends' phones cannot look it up and judge it with unknown facts.
    public static func manual(_ name: String) throws -> PlaceCandidate {
        let name = try PlaceName(name)
        return PlaceCandidate(choice: try PlaceChoice(name: name), facts: PlaceFacts(name: name))
    }
}
