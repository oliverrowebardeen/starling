import CryptoKit
import Foundation

/// Noise revision 34, section 5.2, with SHA-256 as HASH (section 12.5).
struct NoiseSymmetricState: Sendable {
    static let hashLength = 32

    private(set) var cipher = NoiseCipherState()
    private var chainingKey: Data
    private(set) var handshakeHash: Data

    /// InitializeSymmetric(protocol_name).
    init(protocolName: Data) {
        if protocolName.count <= Self.hashLength {
            handshakeHash = protocolName + Data(count: Self.hashLength - protocolName.count)
        } else {
            handshakeHash = Self.hash(protocolName)
        }
        chainingKey = handshakeHash
    }

    /// MixKey(input_key_material).
    mutating func mixKey(_ inputKeyMaterial: Data) {
        let outputs = Self.hkdf(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial, outputs: 2)
        chainingKey = outputs[0]
        cipher = NoiseCipherState(key: SymmetricKey(data: outputs[1]))
    }

    /// MixHash(data).
    mutating func mixHash(_ data: Data) {
        handshakeHash = Self.hash(handshakeHash + data)
    }

    /// EncryptAndHash(plaintext).
    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipher.encrypt(ad: handshakeHash, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    /// DecryptAndHash(ciphertext).
    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipher.decrypt(ad: handshakeHash, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    /// Split(): (initiator-to-responder, responder-to-initiator).
    func split() -> (NoiseCipherState, NoiseCipherState) {
        let outputs = Self.hkdf(chainingKey: chainingKey, inputKeyMaterial: Data(), outputs: 2)
        return (NoiseCipherState(key: SymmetricKey(data: outputs[0])), NoiseCipherState(key: SymmetricKey(data: outputs[1])))
    }

    static func hash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Section 4.3: HKDF with `chaining_key` as the HMAC key, written out
    /// step by step as the spec states it.
    static func hkdf(chainingKey: Data, inputKeyMaterial: Data, outputs: Int) -> [Data] {
        precondition(outputs == 2 || outputs == 3)
        let tempKey = SymmetricKey(data: hmac(key: SymmetricKey(data: chainingKey), inputKeyMaterial))
        let output1 = hmac(key: tempKey, Data([0x01]))
        let output2 = hmac(key: tempKey, output1 + Data([0x02]))
        guard outputs == 3 else { return [output1, output2] }
        let output3 = hmac(key: tempKey, output2 + Data([0x03]))
        return [output1, output2, output3]
    }

    private static func hmac(key: SymmetricKey, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }
}
