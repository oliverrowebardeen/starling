import CryptoKit
import Foundation
@testable import StarlingIdentity
import Testing

@Suite struct NoiseHandshakeTests {
    let alice = X25519PrivateKey()
    let bob = X25519PrivateKey()

    func kk(_ initiatorKey: X25519PrivateKey, believes responderKey: X25519PublicKey,
            _ responder: X25519PrivateKey, believes initiatorPublic: X25519PublicKey,
            prologue: Data = Data()) throws -> (NoiseHandshakeState, NoiseHandshakeState) {
        (
            try NoiseHandshakeState(pattern: .kk, initiator: true, prologue: prologue, localStatic: initiatorKey, remoteStatic: responderKey),
            try NoiseHandshakeState(pattern: .kk, initiator: false, prologue: prologue, localStatic: responder, remoteStatic: initiatorPublic)
        )
    }

    @Test func kkRoundTripsAndAgreesOnKeys() throws {
        var (i, r) = try kk(alice, believes: bob.publicKey, bob, believes: alice.publicKey)
        #expect(try r.readMessage(i.writeMessage(payload: Data("hi".utf8))) == Data("hi".utf8))
        #expect(try i.readMessage(r.writeMessage(payload: Data())) == Data())
        var si = try i.session(), sr = try r.session()
        #expect(si.handshakeHash == sr.handshakeHash)
        #expect(si.remoteStatic.rawRepresentation == bob.publicKey.rawRepresentation)
        #expect(sr.remoteStatic.rawRepresentation == alice.publicKey.rawRepresentation)
        #expect(try sr.receive.decrypt(ad: Data(), ciphertext: si.send.encrypt(ad: Data(), plaintext: Data("x".utf8))) == Data("x".utf8))
        #expect(try si.receive.decrypt(ad: Data(), ciphertext: sr.send.encrypt(ad: Data(), plaintext: Data("y".utf8))) == Data("y".utf8))
    }

    /// Mallory holds her own key but claims to be Alice to Bob, who pinned Alice.
    @Test func kkRejectsAnInitiatorWithoutThePinnedKey() throws {
        let mallory = X25519PrivateKey()
        var (i, r) = try kk(mallory, believes: bob.publicKey, bob, believes: alice.publicKey)
        #expect(throws: NoiseError.decryptionFailed) { try r.readMessage(i.writeMessage(payload: Data())) }
    }

    /// Alice pinned Bob, but Mallory answers in his place.
    @Test func kkRejectsAResponderWithoutThePinnedKey() throws {
        let mallory = X25519PrivateKey()
        var (i, r) = try kk(alice, believes: bob.publicKey, mallory, believes: alice.publicKey)
        // Mallory cannot compute ss = DH(alice, bob), so she cannot read message 1.
        #expect(throws: NoiseError.decryptionFailed) { try r.readMessage(i.writeMessage(payload: Data())) }
    }

    @Test func mismatchedProloguesFail() throws {
        var i = try NoiseHandshakeState(pattern: .kk, initiator: true, prologue: Data("v1".utf8), localStatic: alice, remoteStatic: bob.publicKey)
        var r = try NoiseHandshakeState(pattern: .kk, initiator: false, prologue: Data("v2".utf8), localStatic: bob, remoteStatic: alice.publicKey)
        #expect(throws: NoiseError.decryptionFailed) { try r.readMessage(i.writeMessage(payload: Data())) }
    }

    @Test func everyBitFlipInAnXXMessageIsDetected() throws {
        var i = try NoiseHandshakeState(pattern: .xx, initiator: true, prologue: Data(), localStatic: alice, remoteStatic: nil)
        var r = try NoiseHandshakeState(pattern: .xx, initiator: false, prologue: Data(), localStatic: bob, remoteStatic: nil)
        _ = try r.readMessage(i.writeMessage(payload: Data()))
        let message2 = try r.writeMessage(payload: Data("payload".utf8))
        for index in message2.indices {
            var copy = i
            var tampered = message2
            tampered[index] ^= 0x01
            #expect(throws: NoiseError.self) { try copy.readMessage(tampered) }
        }
        _ = try i.readMessage(message2)
    }

    @Test func truncatedMessagesFail() throws {
        var i = try NoiseHandshakeState(pattern: .xx, initiator: true, prologue: Data(), localStatic: alice, remoteStatic: nil)
        var r = try NoiseHandshakeState(pattern: .xx, initiator: false, prologue: Data(), localStatic: bob, remoteStatic: nil)
        _ = try r.readMessage(i.writeMessage(payload: Data()))
        let message2 = try r.writeMessage(payload: Data())
        for length in [0, 31, 32, 63, 64, 79, message2.count - 1] {
            var copy = i
            #expect(throws: NoiseError.self) { try copy.readMessage(message2.prefix(length)) }
        }
    }

    /// Low-order points give an all-zero DH output; CryptoKit signals an error
    /// (allowed by section 12.1) and the handshake fails instead of continuing.
    @Test func lowOrderEphemeralKeysAreRejected() throws {
        var r = try NoiseHandshakeState(pattern: .xx, initiator: false, prologue: Data(), localStatic: bob, remoteStatic: nil)
        _ = try r.readMessage(Data(count: 32))
        #expect(throws: NoiseError.invalidKey) { try r.writeMessage(payload: Data()) }
    }

    @Test func messagesMustAlternate() throws {
        var i = try NoiseHandshakeState(pattern: .xx, initiator: true, prologue: Data(), localStatic: alice, remoteStatic: nil)
        #expect(throws: NoiseError.malformedMessage) { try i.readMessage(Data(count: 32)) }
        var r = try NoiseHandshakeState(pattern: .xx, initiator: false, prologue: Data(), localStatic: bob, remoteStatic: nil)
        #expect(throws: NoiseError.malformedMessage) { try r.writeMessage(payload: Data()) }
    }

    @Test func patternsRequireTheRightKeys() {
        #expect(throws: NoiseError.invalidConfiguration) {
            try NoiseHandshakeState(pattern: .kk, initiator: true, prologue: Data(), localStatic: alice, remoteStatic: nil)
        }
        #expect(throws: NoiseError.invalidConfiguration) {
            try NoiseHandshakeState(pattern: .xx, initiator: true, prologue: Data(), localStatic: alice, remoteStatic: bob.publicKey)
        }
    }

    @Test func sessionIsUnavailableUntilTheHandshakeEnds() throws {
        var i = try NoiseHandshakeState(pattern: .kk, initiator: true, prologue: Data(), localStatic: alice, remoteStatic: bob.publicKey)
        _ = try i.writeMessage(payload: Data())
        #expect(throws: NoiseError.invalidConfiguration) { try i.session() }
    }
}

@Suite struct NoiseCipherStateTests {
    let key = SymmetricKey(size: .bits256)

    /// Section 5.1: n = 2^64-1 is reserved, so the last usable nonce is 2^64-2.
    @Test func nonceExhaustionIsAnError() throws {
        var sender = NoiseCipherState(key: key)
        var receiver = NoiseCipherState(key: key)
        sender.setNonce(.max - 1)
        receiver.setNonce(.max - 1)
        let last = try sender.encrypt(ad: Data(), plaintext: Data("last".utf8))
        #expect(try receiver.decrypt(ad: Data(), ciphertext: last) == Data("last".utf8))
        #expect(throws: NoiseError.nonceExhausted) { try sender.encrypt(ad: Data(), plaintext: Data()) }
        #expect(throws: NoiseError.nonceExhausted) { try receiver.decrypt(ad: Data(), ciphertext: last) }
    }

    @Test func failedDecryptionDoesNotAdvanceTheNonce() throws {
        var sender = NoiseCipherState(key: key)
        var receiver = NoiseCipherState(key: key)
        let first = try sender.encrypt(ad: Data(), plaintext: Data("one".utf8))
        #expect(first.startIndex == 0, "ciphertext must be indexable from 0")
        var forged = first
        forged[0] ^= 0xFF
        #expect(throws: NoiseError.decryptionFailed) { try receiver.decrypt(ad: Data(), ciphertext: forged) }
        #expect(throws: NoiseError.decryptionFailed) { try receiver.decrypt(ad: Data(), ciphertext: Data(count: 15)) }
        #expect(receiver.nonce == 0)
        #expect(try receiver.decrypt(ad: Data(), ciphertext: first) == Data("one".utf8))
        #expect(receiver.nonce == 1)
    }

    @Test func aReplayedCiphertextFailsUnderTheNextNonce() throws {
        var sender = NoiseCipherState(key: key)
        var receiver = NoiseCipherState(key: key)
        let first = try sender.encrypt(ad: Data(), plaintext: Data("one".utf8))
        _ = try receiver.decrypt(ad: Data(), ciphertext: first)
        #expect(throws: NoiseError.decryptionFailed) { try receiver.decrypt(ad: Data(), ciphertext: first) }
    }

    @Test func emptyKeyPassesThrough() throws {
        var cipher = NoiseCipherState()
        #expect(!cipher.hasKey)
        #expect(try cipher.encrypt(ad: Data(), plaintext: Data("p".utf8)) == Data("p".utf8))
    }
}
