import Foundation
import Security

/// A thrown Keychain status. Carries the `OSStatus` only, never item data.
public struct KeychainError: Error, Hashable, Sendable, CustomStringConvertible {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
    public var description: String { "KeychainError(\(status))" }
}

/// The few generic-password operations the stores need. `SystemKeychain` is
/// the real one; tests inject an in-memory backend so logic runs on any host.
///
/// Every item is written with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// (ADR 0003 care requirement 5): readable once the phone has been unlocked
/// after boot, so Wi-Fi Aware links in the background still work, and never
/// included in backups or synced to another device.
public protocol KeychainBackend: Sendable {
    func read(service: String, account: String) throws -> Data?
    /// Adds a new item. Throws `KeychainError(status: errSecDuplicateItem)` if one exists.
    func add(service: String, account: String, data: Data) throws
    /// Replaces the data of an existing item, or adds it.
    func upsert(service: String, account: String, data: Data) throws
    /// Deletes the item if present.
    func delete(service: String, account: String) throws
}

/// The system Keychain, through `SecItem`.
public struct SystemKeychain: KeychainBackend {
    public init() {}

    public func read(service: String, account: String) throws -> Data? {
        var query = Self.baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    public func add(service: String, account: String, data: Data) throws {
        let status = SecItemAdd(Self.addQuery(service: service, account: account, data: data) as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func upsert(service: String, account: String, data: Data) throws {
        let attributes = [kSecValueData as String: data] as CFDictionary
        let status = SecItemUpdate(Self.baseQuery(service: service, account: account) as CFDictionary, attributes)
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: try add(service: service, account: account, data: data)
        default: throw KeychainError(status: status)
        }
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(Self.baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // The iOS-style keychain on every platform, so the accessibility
            // class below means the same thing on Mac Catalyst and macOS.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func addQuery(service: String, account: String, data: Data) -> [String: Any] {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false
        return query
    }
}
