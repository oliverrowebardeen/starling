import CryptoKit
import Foundation

/// A peer's long-term X25519 public key: the Noise "static" key exchanged and
/// pinned at pairing (ADR 0003). Only the public half ever appears in Core.
public struct IdentityPublicKey: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 32

    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw ValidationError("IdentityPublicKey", "expected \(Self.byteCount) bytes, got \(bytes.count)")
        }
        self.bytes = Data(bytes)
    }

    public init(hex: String) throws {
        try self.init(bytes: Hex.decode(hex, byteCount: Self.byteCount, field: "IdentityPublicKey"))
    }

    /// The ID every Starling component uses for this peer: SHA-256 of the raw
    /// key bytes. Nobody can claim an ID without holding the matching key.
    public var peerID: PeerID {
        // Force-try is safe: SHA-256 output is always 32 bytes.
        try! PeerID(bytes: Data(SHA256.hash(data: bytes)))
    }

    public var hex: String { Hex.encode(bytes) }
    public var description: String { "IdentityPublicKey(\(peerID.short))" }
}

extension IdentityPublicKey: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(hex: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

extension PeerID {
    /// The key-derived ID (Phase 1 onward). `PeerID.random()` remains for tests.
    public init(publicKey: IdentityPublicKey) {
        self = publicKey.peerID
    }
}

/// A friend paired in person: their pinned key plus a local nickname.
/// The nickname is the owner's label and never leaves the device.
public struct PairedPeer: Hashable, Sendable {
    public static let maxNicknameCharacters = 40

    public let id: PeerID
    public let publicKey: IdentityPublicKey
    public let nickname: String
    public let pairedAt: Timestamp

    public init(publicKey: IdentityPublicKey, nickname: String, pairedAt: Timestamp) throws {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...Self.maxNicknameCharacters).contains(trimmed.count),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw ValidationError("PairedPeer.nickname", "must be 1-\(Self.maxNicknameCharacters) characters, no control characters") }
        id = publicKey.peerID
        self.publicKey = publicKey
        self.nickname = trimmed
        self.pairedAt = pairedAt
    }
}

extension PairedPeer: Codable {
    private enum CodingKeys: String, CodingKey { case id, publicKey, nickname, pairedAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            publicKey: c.decode(IdentityPublicKey.self, forKey: .publicKey),
            nickname: c.decode(String.self, forKey: .nickname),
            pairedAt: c.decode(Timestamp.self, forKey: .pairedAt)
        )
        // A stored ID that does not match its key means corrupted or forged storage.
        guard try c.decode(PeerID.self, forKey: .id) == id else {
            throw ValidationError("PairedPeer", "stored id does not match public key")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(publicKey, forKey: .publicKey)
        try c.encode(nickname, forKey: .nickname)
        try c.encode(pairedAt, forKey: .pairedAt)
    }
}

/// Where pinned friends live. The real store (Keychain-backed) is lane E1's;
/// `StarlingFakes.InMemoryPairedPeerStore` stands in for tests.
public protocol PairedPeerStore: Sendable {
    func all() async throws -> [PairedPeer]
    func peer(for id: PeerID) async throws -> PairedPeer?
    /// Inserts or replaces the peer with the same ID.
    func save(_ peer: PairedPeer) async throws
    func remove(_ id: PeerID) async throws
}

// MARK: - Pairing ceremony

public enum PairingFailure: String, Error, Hashable, Sendable, Codable {
    /// The owner said the codes on the two phones differ: possible attacker.
    case codeMismatch
    case cancelled
    case timedOut
    case transportFailed
    /// The other side sent something the handshake did not expect.
    case protocolError
}

public enum PairingEvent: Hashable, Sendable {
    /// Show this short code; both people compare it and confirm (ADR 0003).
    case confirmCode(String)
    /// Keys exchanged, verified, and pinned.
    case paired(PairedPeer)
    case failed(PairingFailure)
}

/// One in-person pairing ceremony, as the UI sees it. Lane E1 implements the
/// key exchange behind it; lane H drives it from the pairing screen. How a
/// session starts depends on the link (Wi-Fi Aware via lane E2, or a
/// fallback), so starting one is the implementing lane's API, not Core's.
public protocol PairingSession: Sendable {
    /// Single consumer. Finishes after `.paired` or `.failed`.
    var events: AsyncStream<PairingEvent> { get }
    /// The owner compared the codes shown on both phones.
    func confirm(codesMatch: Bool) async
    func cancel() async
}

// MARK: - Hex

enum Hex {
    static func encode(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Parses ASCII hex digits from UTF-8 bytes, never `Character` indices,
    /// so hostile input throws instead of indexing out of bounds.
    static func decode(_ hex: String, byteCount: Int, field: String) throws -> Data {
        let digits = Array(hex.utf8)
        guard digits.count == byteCount * 2 else {
            throw ValidationError(field, "expected \(byteCount * 2) hex characters")
        }
        var result = Data(capacity: byteCount)
        for pair in stride(from: 0, to: digits.count, by: 2) {
            guard let high = value(digits[pair]), let low = value(digits[pair + 1]) else {
                throw ValidationError(field, "invalid hex")
            }
            result.append(high << 4 | low)
        }
        return result
    }

    private static func value(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
