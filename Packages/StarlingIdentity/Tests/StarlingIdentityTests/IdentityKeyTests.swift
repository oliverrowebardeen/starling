import CryptoKit
import Foundation
import Security
import StarlingCore
@testable import StarlingIdentity
import Testing

/// A Keychain stand-in that behaves like `SecItem` for generic passwords.
final class InMemoryKeychain: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func read(service: String, account: String) throws -> Data? {
        lock.withLock { items[service + "/" + account] }
    }

    func add(service: String, account: String, data: Data) throws {
        try lock.withLock {
            guard items[service + "/" + account] == nil else { throw KeychainError(status: errSecDuplicateItem) }
            items[service + "/" + account] = data
        }
    }

    func upsert(service: String, account: String, data: Data) throws {
        lock.withLock { items[service + "/" + account] = data }
    }

    func delete(service: String, account: String) throws {
        _ = lock.withLock { items.removeValue(forKey: service + "/" + account) }
    }

    func corrupt(service: String, account: String, with data: Data) {
        lock.withLock { items[service + "/" + account] = data }
    }
}

@Suite struct IdentityKeyTests {
    @Test func peerIDIsTheCoreDerivation() {
        let identity = IdentityKeyPair.generate()
        #expect(identity.peerID == PeerID(publicKey: identity.publicKey))
        #expect(identity.publicKey.bytes == identity.privateKey.publicKey.rawRepresentation)
    }

    /// ADR 0003 care requirement 5: printing, debugging, or dumping an
    /// identity never reveals the private key.
    @Test func privateKeyNeverAppearsInTextOutput() {
        let identity = IdentityKeyPair.generate()
        let secretHex = identity.rawPrivateKey.map { String(format: "%02x", $0) }.joined()
        var dumped = ""
        dump(identity, to: &dumped)
        let outputs = [
            String(describing: identity),
            String(reflecting: identity),
            "\(identity)",
            dumped,
            String(describing: Mirror(reflecting: identity).children.map(\.value)),
        ]
        for output in outputs {
            #expect(!output.contains(secretHex))
            #expect(!output.lowercased().contains("privatekey"))
        }
        #expect(String(describing: identity) == "IdentityKeyPair(\(identity.peerID.short))")
    }

    @Test func keychainStoreCreatesOnceAndReloads() async throws {
        let keychain = InMemoryKeychain()
        let store = KeychainIdentityKeyStore(backend: keychain, service: "test")
        #expect(try await store.load() == nil)
        let created = try await store.loadOrCreate()
        #expect(try await store.loadOrCreate().publicKey == created.publicKey)
        let reopened = KeychainIdentityKeyStore(backend: keychain, service: "test")
        #expect(try await reopened.load()?.publicKey == created.publicKey)
        try await store.delete()
        #expect(try await reopened.load() == nil)
    }

    @Test func keychainStoreKeepsAnExistingKeyOnARace() async throws {
        let keychain = InMemoryKeychain()
        let first = KeychainIdentityKeyStore(backend: keychain, service: "race")
        let second = KeychainIdentityKeyStore(backend: keychain, service: "race")
        async let a = first.loadOrCreate()
        async let b = second.loadOrCreate()
        let (x, y) = try await (a, b)
        #expect(x.publicKey == y.publicKey)
    }

    @Test func corruptedKeyMaterialThrowsInsteadOfReplacingTheIdentity() async throws {
        let keychain = InMemoryKeychain()
        keychain.corrupt(service: "bad", account: KeychainIdentityKeyStore.account, with: Data(count: 5))
        let store = KeychainIdentityKeyStore(backend: keychain, service: "bad")
        await #expect(throws: IdentityKeyStoreError.corrupted) { try await store.loadOrCreate() }
    }

    @Test func inMemoryStore() async throws {
        let store = InMemoryIdentityKeyStore()
        #expect(await store.load() == nil)
        let created = await store.loadOrCreate()
        #expect(await store.loadOrCreate().publicKey == created.publicKey)
        await store.delete()
        #expect(await store.load() == nil)
    }

    /// The attributes the real Keychain receives: this-device-only, after first
    /// unlock, never synced, data protection keychain.
    @Test func systemKeychainAddsWithTheRequiredAccessibility() {
        let query = SystemKeychain.addQuery(service: "s", account: "a", data: Data([1]))
        #expect(query[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "s")
        #expect(query[kSecAttrAccount as String] as? String == "a")
    }
}

/// The real Keychain. Opt-in (STARLING_KEYCHAIN_TESTS=1): unsigned test
/// binaries on macOS usually lack the entitlement the data protection
/// keychain needs, so this runs on signed hosts and devices.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STARLING_KEYCHAIN_TESTS"] == "1"))
struct SystemKeychainTests {
    @Test func identityRoundTripsThroughTheRealKeychain() async throws {
        let service = "com.oliverrowebardeen.starling.tests.\(UUID().uuidString)"
        let store = KeychainIdentityKeyStore(service: service)
        defer { try? SystemKeychain().delete(service: service, account: KeychainIdentityKeyStore.account) }
        let created = try await store.loadOrCreate()
        #expect(try await KeychainIdentityKeyStore(service: service).load()?.publicKey == created.publicKey)
        try await store.delete()
        #expect(try await store.load() == nil)
    }
}
