import CryptoKit
import Foundation

/// Errors from the Noise layer. None of them carries key material or peer
/// data, and none is ever sent on the wire (ADR 0003 care requirement 4).
enum NoiseError: Error, Hashable, Sendable {
    /// AEAD authentication failed, or a ciphertext was too short to hold a tag.
    case decryptionFailed
    /// CryptoKit refused to seal. Not expected with a valid key and nonce.
    case encryptionFailed
    /// The nonce reached 2^64-1, which Noise reserves. The session must end.
    case nonceExhausted
    /// A handshake message had the wrong length or arrived out of turn.
    case malformedMessage
    /// A public key or DH output was rejected by CryptoKit.
    case invalidKey
    /// The handshake was initialized with the wrong set of keys for its pattern.
    case invalidConfiguration
}

/// Noise revision 34, section 5.1: a key `k` (possibly empty) and a 64-bit
/// nonce `n`, over ChaChaPoly (section 12.3).
struct NoiseCipherState: Sendable {
    static let tagLength = 16

    private var key: SymmetricKey?
    /// The next nonce. `UInt64.max` is reserved; reaching it ends the session.
    private(set) var nonce: UInt64 = 0

    /// InitializeKey(empty).
    init() {}

    /// InitializeKey(key).
    init(key: SymmetricKey) {
        self.key = key
    }

    /// HasKey().
    var hasKey: Bool { key != nil }

    /// SetNonce(nonce), for explicit nonces on transport messages (section 11.4).
    mutating func setNonce(_ nonce: UInt64) {
        self.nonce = nonce
    }

    /// EncryptWithAd(ad, plaintext).
    mutating func encrypt(ad: Data, plaintext: Data) throws -> Data {
        guard let key else { return plaintext }
        guard nonce < .max else { throw NoiseError.nonceExhausted }
        let sealed: ChaChaPoly.SealedBox
        do {
            sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: Self.chachaNonce(nonce), authenticating: ad)
        } catch {
            throw NoiseError.encryptionFailed
        }
        nonce += 1
        // `sealed.ciphertext` is a slice of the combined box with a non-zero
        // start index; copy so callers can index the result from 0.
        var output = Data(capacity: plaintext.count + Self.tagLength)
        output.append(contentsOf: sealed.ciphertext)
        output.append(contentsOf: sealed.tag)
        return output
    }

    /// DecryptWithAd(ad, ciphertext). On failure `n` is not incremented.
    mutating func decrypt(ad: Data, ciphertext: Data) throws -> Data {
        guard let key else { return ciphertext }
        guard nonce < .max else { throw NoiseError.nonceExhausted }
        guard ciphertext.count >= Self.tagLength else { throw NoiseError.decryptionFailed }
        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: Self.chachaNonce(nonce),
                ciphertext: ciphertext.prefix(ciphertext.count - Self.tagLength),
                tag: ciphertext.suffix(Self.tagLength)
            )
            plaintext = Data(try ChaChaPoly.open(box, using: key, authenticating: ad))
        } catch {
            throw NoiseError.decryptionFailed
        }
        nonce += 1
        return plaintext
    }

    /// Section 12.3: 32 bits of zeros, then `n` little-endian.
    private static func chachaNonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: n.littleEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }
}
