import CryptoKit
import Foundation
import StarlingCore
import StarlingFakes
import Testing

@Suite struct IdentityTests {
    func key(_ byte: UInt8) throws -> IdentityPublicKey { try IdentityPublicKey(bytes: Data(repeating: byte, count: 32)) }

    @Test func peerIDIsSHA256OfTheKey() throws {
        let agreementKey = Curve25519.KeyAgreement.PrivateKey().publicKey
        let publicKey = try IdentityPublicKey(bytes: agreementKey.rawRepresentation)
        #expect(PeerID(publicKey: publicKey).bytes == Data(SHA256.hash(data: agreementKey.rawRepresentation)))
        #expect(publicKey.peerID == PeerID(publicKey: publicKey))
    }

    @Test func keysValidateLengthAndHex() throws {
        #expect(throws: ValidationError.self) { try IdentityPublicKey(bytes: Data(count: 31)) }
        #expect(throws: ValidationError.self) { try IdentityPublicKey(hex: String(repeating: "0", count: 62) + "é") }
        let original = try key(0xAB)
        #expect(try IdentityPublicKey(hex: original.hex) == original)
        #expect(try JSONDecoder().decode(IdentityPublicKey.self, from: JSONEncoder().encode(original)) == original)
    }

    @Test func pairedPeersDeriveTheirIDAndValidateNicknames() throws {
        let peer = try PairedPeer(publicKey: key(1), nickname: "  Maya ", pairedAt: Timestamp(millisecondsSince1970: 0))
        #expect(peer.id == (try key(1)).peerID)
        #expect(peer.nickname == "Maya")
        #expect(throws: ValidationError.self) { try PairedPeer(publicKey: key(1), nickname: " ", pairedAt: Timestamp(millisecondsSince1970: 0)) }
        #expect(throws: ValidationError.self) { try PairedPeer(publicKey: key(1), nickname: "a\u{0}b", pairedAt: Timestamp(millisecondsSince1970: 0)) }
        #expect(throws: ValidationError.self) {
            try PairedPeer(publicKey: key(1), nickname: String(repeating: "x", count: 41), pairedAt: Timestamp(millisecondsSince1970: 0))
        }
    }

    /// Storage whose ID does not match its key is corrupt or forged.
    @Test func decodingRejectsAMismatchedID() throws {
        let peer = try PairedPeer(publicKey: key(1), nickname: "Maya", pairedAt: Timestamp(millisecondsSince1970: 0))
        let json = String(decoding: try JSONEncoder().encode(peer), as: UTF8.self)
            .replacingOccurrences(of: peer.id.hex, with: (try key(2)).peerID.hex)
        #expect(throws: ValidationError.self) { _ = try JSONDecoder().decode(PairedPeer.self, from: Data(json.utf8)) }
        #expect(try JSONDecoder().decode(PairedPeer.self, from: JSONEncoder().encode(peer)) == peer)
    }

    @Test func inMemoryStoreRoundTrips() async throws {
        let store = InMemoryPairedPeerStore()
        let maya = try PairedPeer(publicKey: key(1), nickname: "Maya", pairedAt: Timestamp(millisecondsSince1970: 2))
        let sam = try PairedPeer(publicKey: key(2), nickname: "Sam", pairedAt: Timestamp(millisecondsSince1970: 1))
        try await store.save(maya)
        try await store.save(sam)
        #expect(try await store.all() == [sam, maya])
        #expect(try await store.peer(for: maya.id) == maya)
        try await store.remove(maya.id)
        #expect(try await store.all() == [sam])
    }

    @Test func scriptedPairingSucceedsOnlyWhenCodesMatch() async throws {
        let maya = try PairedPeer(publicKey: key(1), nickname: "Maya", pairedAt: Timestamp(millisecondsSince1970: 0))
        for (match, expected) in [(true, PairingEvent.paired(maya)), (false, .failed(.codeMismatch))] {
            let session = ScriptedPairingSession(code: "4 1 7 2", peer: maya)
            await session.confirm(codesMatch: match)
            var events: [PairingEvent] = []
            for await event in session.events { events.append(event) }
            #expect(events == [.confirmCode("4 1 7 2"), expected])
        }
    }
}
