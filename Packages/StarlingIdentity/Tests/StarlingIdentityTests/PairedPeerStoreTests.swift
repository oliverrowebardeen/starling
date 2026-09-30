import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingIdentity
import Testing

@Suite struct PairedPeerStoreTests {
    func peer(_ nickname: String, at millis: Int64) throws -> PairedPeer {
        try PairedPeer(publicKey: IdentityKeyPair.generate().publicKey, nickname: nickname, pairedAt: Timestamp(millisecondsSince1970: millis))
    }

    /// The Keychain store and Core's in-memory fake behave the same.
    @Test func keychainStoreMatchesTheCoreContract() async throws {
        let stores: [any PairedPeerStore] = [
            KeychainPairedPeerStore(backend: InMemoryKeychain(), service: "peers"),
            InMemoryPairedPeerStore(),
        ]
        for store in stores {
            let maya = try peer("Maya", at: 2)
            let sam = try peer("Sam", at: 1)
            try await store.save(maya)
            try await store.save(sam)
            #expect(try await store.all() == [sam, maya])
            #expect(try await store.peer(for: maya.id) == maya)

            let renamed = try PairedPeer(publicKey: maya.publicKey, nickname: "Maya R", pairedAt: maya.pairedAt)
            try await store.save(renamed)
            #expect(try await store.all() == [sam, renamed])

            try await store.remove(sam.id)
            try await store.remove(sam.id)
            #expect(try await store.all() == [renamed])
            #expect(try await store.peer(for: sam.id) == nil)
        }
    }

    @Test func keychainStorePersistsAcrossInstances() async throws {
        let keychain = InMemoryKeychain()
        let maya = try peer("Maya", at: 1)
        try await KeychainPairedPeerStore(backend: keychain, service: "peers").save(maya)
        #expect(try await KeychainPairedPeerStore(backend: keychain, service: "peers").all() == [maya])
        #expect(try await KeychainPairedPeerStore(backend: keychain, service: "other").all() == [])
    }

    /// A forged entry whose ID does not match its key, or any unreadable
    /// data, throws rather than silently dropping or trusting entries.
    @Test func corruptedStorageThrows() async throws {
        let keychain = InMemoryKeychain()
        let store = KeychainPairedPeerStore(backend: keychain, service: "peers")
        let maya = try peer("Maya", at: 1)
        try await store.save(maya)
        let stored = try #require(try keychain.read(service: "peers", account: KeychainPairedPeerStore.account))
        let forged = String(decoding: stored, as: UTF8.self)
            .replacingOccurrences(of: maya.id.hex, with: PeerID.random().hex)
        keychain.corrupt(service: "peers", account: KeychainPairedPeerStore.account, with: Data(forged.utf8))
        await #expect(throws: PairedPeerStoreError.corrupted) { try await store.all() }
        keychain.corrupt(service: "peers", account: KeychainPairedPeerStore.account, with: Data("garbage".utf8))
        await #expect(throws: PairedPeerStoreError.corrupted) { try await store.save(try peer("Sam", at: 2)) }
    }
}
