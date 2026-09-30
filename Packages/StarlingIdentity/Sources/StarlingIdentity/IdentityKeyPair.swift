import CryptoKit
import Foundation
import StarlingCore

typealias X25519PrivateKey = Curve25519.KeyAgreement.PrivateKey
typealias X25519PublicKey = Curve25519.KeyAgreement.PublicKey

/// This device's long-term X25519 identity: the Noise static key pair (ADR 0003).
///
/// The private half never leaves this module except into the Keychain. The
/// type is deliberately not `Codable`, and its description, debug description,
/// and reflection show only the public key's short ID, so `print`, `dump`, and
/// string interpolation cannot leak it (ADR 0003 care requirement 5).
public struct IdentityKeyPair: Sendable {
    let privateKey: X25519PrivateKey
    public let publicKey: IdentityPublicKey

    init(privateKey: X25519PrivateKey) {
        self.privateKey = privateKey
        // Force-try is safe: an X25519 public key is always 32 bytes.
        publicKey = try! IdentityPublicKey(bytes: privateKey.publicKey.rawRepresentation)
    }

    /// Restores a key from its 32-byte raw representation (Keychain only).
    init(rawPrivateKey: Data) throws {
        do {
            self.init(privateKey: try X25519PrivateKey(rawRepresentation: rawPrivateKey))
        } catch {
            throw IdentityKeyStoreError.corrupted
        }
    }

    /// A fresh key pair from the system random number generator.
    public static func generate() -> IdentityKeyPair {
        IdentityKeyPair(privateKey: X25519PrivateKey())
    }

    /// The ID other devices know this one by: SHA-256 of the public key.
    public var peerID: PeerID { publicKey.peerID }

    /// For the Keychain write only. Never log or encode the result.
    var rawPrivateKey: Data { privateKey.rawRepresentation }
}

extension IdentityKeyPair: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "IdentityKeyPair(\(peerID.short))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["publicKey": publicKey], displayStyle: .struct) }
}
