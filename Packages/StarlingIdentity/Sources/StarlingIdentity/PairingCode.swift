import CryptoKit
import Foundation

/// The short authentication string both owners compare (ADR 0101).
///
/// A code taken from the Noise handshake hash alone is not enough: a man in
/// the middle who sends the last handshake message in one of its two
/// sessions can try new keys until the two 6-digit codes collide, which takes
/// about a million X25519 operations. So each side adds a 32-byte nonce, and
/// the responder commits to its nonce before it sees the initiator's (the
/// construction behind Bluetooth numeric comparison). The attacker must then
/// fix every input it controls before learning one it does not, and a
/// ceremony succeeds for it with probability 1 in 10^6.
enum PairingCode {
    static let nonceLength = 32
    static let digits = 6

    static func nonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<nonceLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// The responder's commitment, sent inside handshake message 2.
    static func commitment(to nonce: Data) -> Data {
        Data(SHA256.hash(data: Data("Starling pairing commitment v1".utf8) + nonce))
    }

    /// Six decimal digits from the handshake hash (Noise section 11.2 channel
    /// binding) and both nonces. The modulo bias is below 2^-44.
    static func code(handshakeHash: Data, initiatorNonce: Data, responderNonce: Data) -> String {
        let digest = SHA256.hash(data: Data("Starling pairing code v1".utf8) + handshakeHash + initiatorNonce + responderNonce)
        let value = digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 1_000_000
        let text = String(value)
        return String(repeating: "0", count: digits - text.count) + text
    }
}
