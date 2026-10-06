import Foundation
import Security

public enum IdentityKeyStoreError: Error, Hashable, Sendable {
    /// The stored bytes are not a valid X25519 private key.
    case corrupted
}

/// Where this device's identity key lives.
public protocol IdentityKeyStore: Sendable {
    /// The stored identity, or nil if none has been created.
    func load() async throws -> IdentityKeyPair?
    /// The stored identity, creating and storing one on first use. Never
    /// replaces an existing key, even if two callers race.
    func loadOrCreate() async throws -> IdentityKeyPair
    /// Deletes the identity. Every pinned friend then has to pair again.
    func delete() async throws
}

/// The production store: one generic-password item in the Keychain, written
/// with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (see `KeychainBackend`).
public actor KeychainIdentityKeyStore: IdentityKeyStore {
    public static let defaultService = "starling.identity"
    static let account = "x25519-static-v1"

    private let backend: any KeychainBackend
    private let service: String

    public init(backend: any KeychainBackend = SystemKeychain(), service: String = defaultService) {
        self.backend = backend
        self.service = service
    }

    public func load() throws -> IdentityKeyPair? {
        guard let raw = try backend.read(service: service, account: Self.account) else { return nil }
        return try IdentityKeyPair(rawPrivateKey: raw)
    }

    public func loadOrCreate() throws -> IdentityKeyPair {
        if let existing = try load() { return existing }
        let created = IdentityKeyPair.generate()
        do {
            try backend.add(service: service, account: Self.account, data: created.rawPrivateKey)
            return created
        } catch let error as KeychainError where error.status == errSecDuplicateItem {
            // Another process wrote one first; keep theirs.
            guard let existing = try load() else { throw error }
            return existing
        }
    }

    public func delete() throws {
        try backend.delete(service: service, account: Self.account)
    }
}

/// Keeps the identity in memory only. For tests, previews, and the simulator.
public actor InMemoryIdentityKeyStore: IdentityKeyStore {
    private var identity: IdentityKeyPair?

    public init(_ identity: IdentityKeyPair? = nil) {
        self.identity = identity
    }

    public func load() -> IdentityKeyPair? { identity }

    public func loadOrCreate() -> IdentityKeyPair {
        if let identity { return identity }
        let created = IdentityKeyPair.generate()
        identity = created
        return created
    }

    public func delete() { identity = nil }
}
