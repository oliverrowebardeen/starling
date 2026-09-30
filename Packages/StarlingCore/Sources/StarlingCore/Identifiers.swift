import Foundation

/// An opaque 32-byte peer identifier.
///
/// Phase 0 uses random values. From Phase 1 a `PeerID` is the SHA-256 of the
/// peer's static identity public key (ADR 0003), so it cannot be claimed
/// without the key. Until a secure channel verifies it, a `PeerID` reported by
/// a transport is only a claim.
public struct PeerID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public static let byteCount = 32

    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw ValidationError("PeerID", "expected \(Self.byteCount) bytes, got \(bytes.count)")
        }
        self.bytes = Data(bytes)
    }

    /// Parses 64 ASCII hex digits. Works on UTF-8 bytes, never on
    /// `Character` indices, so hostile input (multi-byte characters, full-width
    /// digits) throws instead of indexing out of bounds.
    public init(hex: String) throws {
        let digits = Array(hex.utf8)
        guard digits.count == Self.byteCount * 2 else {
            throw ValidationError("PeerID", "expected \(Self.byteCount * 2) hex characters")
        }
        var result = Data(capacity: Self.byteCount)
        for pair in stride(from: 0, to: digits.count, by: 2) {
            guard let high = Self.hexValue(digits[pair]), let low = Self.hexValue(digits[pair + 1]) else {
                throw ValidationError("PeerID", "invalid hex")
            }
            result.append(high << 4 | low)
        }
        try self.init(bytes: result)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    public static func random() -> PeerID {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }

    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> PeerID {
        let bytes = Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        // Force-try is safe: the byte count is correct by construction.
        return try! PeerID(bytes: bytes)
    }

    /// Lowercase hex, 64 characters.
    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// First 8 hex characters, for logs and debug UI only.
    public var short: String { String(hex.prefix(8)) }

    public var description: String { "PeerID(\(short))" }

    public static func < (lhs: PeerID, rhs: PeerID) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }
}

extension PeerID: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(hex: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// Unique identifier of one envelope.
public struct MessageID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue.uuidString }
}

/// Groups the envelopes of one negotiation between peers.
public struct ConversationID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue.uuidString }
}

/// Milliseconds since the Unix epoch, UTC. Integer on the wire so encoding is
/// exact and independent of `JSONEncoder` date strategies.
public struct Timestamp: Hashable, Comparable, Sendable, Codable {
    public let millisecondsSince1970: Int64

    public init(millisecondsSince1970: Int64) { self.millisecondsSince1970 = millisecondsSince1970 }
    public init(_ date: Date) { millisecondsSince1970 = Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    public var date: Date { Date(timeIntervalSince1970: Double(millisecondsSince1970) / 1000) }

    public init(from decoder: any Decoder) throws {
        millisecondsSince1970 = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(millisecondsSince1970)
    }

    public static func < (lhs: Timestamp, rhs: Timestamp) -> Bool {
        lhs.millisecondsSince1970 < rhs.millisecondsSince1970
    }
}
