import Foundation

// Artifacts (Phase 1.5, ADR 0012): the typed results skills hand to each
// other. A Plan comes out of Down for… or Find a time; Pick a place accepts
// it and produces a PlaceChoice that updates it; Swap photos accepts it and
// starts when it ends. Plans live on each phone (each side builds its own
// from the agreed terms); places also travel as `IssueValue.places` while
// agents agree on one.

/// A venue's name, as shown to people: bounded display text that a peer may
/// send. It is never an instruction: models see it only as a typed
/// candidate value, and policy decides egress (ADR 0012, ARCHITECTURE rule 7).
public struct PlaceName: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        guard (1...ProtocolLimits.maxPlaceNameCharacters).contains(trimmed.count) else {
            throw ValidationError("PlaceName", "must be 1-\(ProtocolLimits.maxPlaceNameCharacters) characters")
        }
        guard trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }) else {
            throw ValidationError("PlaceName", "no control characters or line breaks")
        }
        self.rawValue = trimmed
    }

    public var description: String { rawValue }
}

extension PlaceName: Codable {
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A venue's position, to five decimal places (about a metre). A venue is a
/// public place; the owner's own location never travels (topic `place`).
public struct Coordinate: Hashable, Sendable, Codable {
    /// Degrees times 100,000.
    public let latitudeE5: Int32
    public let longitudeE5: Int32

    public init(latitude: Double, longitude: Double) throws {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw ValidationError("Coordinate", "out of range")
        }
        latitudeE5 = Int32((latitude * 100_000).rounded())
        longitudeE5 = Int32((longitude * 100_000).rounded())
    }

    public var latitude: Double { Double(latitudeE5) / 100_000 }
    public var longitude: Double { Double(longitudeE5) / 100_000 }

    private enum CodingKeys: String, CodingKey { case latitudeE5 = "lat", longitudeE5 = "lon" }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(latitude: Double(c.decode(Int32.self, forKey: .latitudeE5)) / 100_000,
                      longitude: Double(c.decode(Int32.self, forKey: .longitudeE5)) / 100_000)
    }
}

/// An agreed venue (Pick a place produces it).
public struct PlaceChoice: Hashable, Sendable, Codable {
    public let name: PlaceName
    public let coordinate: Coordinate?
    /// Apple Maps' identifier for the place, when known, so both phones open
    /// the same venue. Opaque, bounded.
    public let mapItemID: String?

    public init(name: PlaceName, coordinate: Coordinate? = nil, mapItemID: String? = nil) throws {
        if let mapItemID {
            guard (1...ProtocolLimits.maxMapItemIDCharacters).contains(mapItemID.count),
                  mapItemID.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0) && $0 != " " })
            else { throw ValidationError("PlaceChoice.mapItemID", "must be 1-\(ProtocolLimits.maxMapItemIDCharacters) printable ASCII characters") }
        }
        self.name = name
        self.coordinate = coordinate
        self.mapItemID = mapItemID
    }

    private enum CodingKeys: String, CodingKey { case name, coordinate, mapItemID }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            name: c.decode(PlaceName.self, forKey: .name),
            coordinate: c.decodeIfPresent(Coordinate.self, forKey: .coordinate),
            mapItemID: c.decodeIfPresent(String.self, forKey: .mapItemID)
        )
    }
}

/// The confirmed people of a plan, the owner included.
public struct Attendees: Hashable, Sendable, Codable {
    public let peers: [PeerID]

    public init(_ peers: [PeerID]) throws {
        guard (2...ProtocolLimits.maxAttendees).contains(peers.count) else {
            throw ValidationError("Attendees", "must list 2-\(ProtocolLimits.maxAttendees) people")
        }
        guard Set(peers).count == peers.count else { throw ValidationError("Attendees", "lists someone twice") }
        self.peers = peers
    }

    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode([PeerID].self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(peers)
    }
}

public struct PlanID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue.uuidString }
}

/// Who, doing what, when, and where once known. Built on each phone from
/// the terms both agents agreed on, and kept on the phone.
public struct Plan: Hashable, Sendable, Codable, Identifiable {
    public let id: PlanID
    /// The conversation whose agreement produced the plan; chained skills
    /// point back to it with `Envelope.chainedFrom`.
    public let origin: ConversationID
    public let attendees: Attendees
    public let activity: Keyword?
    public let time: TimeSlot?
    public let place: PlaceChoice?
    /// 0 when the plan is first agreed, then one more for every change the
    /// group agrees to (ADR 0022). A change names the revision it changes,
    /// so an answer to an older version of the plan never applies.
    public let revision: UInt32

    public init(id: PlanID = PlanID(), origin: ConversationID, attendees: Attendees, activity: Keyword?, time: TimeSlot?,
                place: PlaceChoice? = nil, revision: UInt32 = 0) throws {
        guard activity != nil || time != nil else { throw ValidationError("Plan", "needs an activity or a time") }
        self.id = id
        self.origin = origin
        self.attendees = attendees
        self.activity = activity
        self.time = time
        self.place = place
        self.revision = revision
    }

    /// The same plan after a change the group agreed to (ADR 0022): any of
    /// who, what, when, and where, with the revision one higher. Throws if
    /// the result would have neither an activity nor a time, or if the
    /// revision cannot rise.
    public func updating(attendees: Attendees? = nil, activity: Keyword?? = nil, time: TimeSlot?? = nil,
                         place: PlaceChoice?? = nil) throws -> Plan {
        guard revision < .max else { throw ValidationError("Plan.revision", "cannot rise further") }
        return try Plan(id: id, origin: origin, attendees: attendees ?? self.attendees,
                        activity: activity ?? self.activity, time: time ?? self.time,
                        place: place ?? self.place, revision: revision + 1)
    }

    /// When a time-triggered chain (Swap photos) may start.
    public var endsAt: Date? { time?.end }

    private enum CodingKeys: String, CodingKey { case id, origin, attendees, activity, time, place, revision }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(PlanID.self, forKey: .id),
            origin: c.decode(ConversationID.self, forKey: .origin),
            attendees: c.decode(Attendees.self, forKey: .attendees),
            activity: c.decodeIfPresent(Keyword.self, forKey: .activity),
            time: c.decodeIfPresent(TimeSlot.self, forKey: .time),
            place: c.decodeIfPresent(PlaceChoice.self, forKey: .place),
            revision: c.decodeIfPresent(UInt32.self, forKey: .revision) ?? 0
        )
    }
}

/// One typed result a skill produces or accepts.
public enum Artifact: Hashable, Sendable, Codable {
    case plan(Plan)
    case timeSlot(TimeSlot)
    case placeChoice(PlaceChoice)
    case attendees(Attendees)

    public var kind: ArtifactKind {
        switch self {
        case .plan: .plan
        case .timeSlot: .timeSlot
        case .placeChoice: .placeChoice
        case .attendees: .attendees
        }
    }
}
