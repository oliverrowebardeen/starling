import Foundation
import StarlingCore

public enum PairedPeerStoreError: Error, Hashable, Sendable {
    /// The stored list could not be decoded. It is left untouched so a later
    /// build can recover it; nothing is silently dropped.
    case corrupted
}

/// Pinned friends, kept in the Keychain as one generic-password item holding
/// a JSON array of `PairedPeer`.
///
/// Public keys are not secret, but the list is who this person is friends
/// with, and a tampered list would let an attacker pin their own key. The
/// Keychain keeps it out of backups and away from other apps. Written with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` like every Starling item.
public actor KeychainPairedPeerStore: PairedPeerStore {
    public static let defaultService = "com.oliverrowebardeen.starling.paired-peers"
    static let account = "paired-peers-v1"

    private let backend: any KeychainBackend
    private let service: String

    public init(backend: any KeychainBackend = SystemKeychain(), service: String = defaultService) {
        self.backend = backend
        self.service = service
    }

    public func all() throws -> [PairedPeer] {
        try load().values.sorted { ($0.pairedAt, $0.id) < ($1.pairedAt, $1.id) }
    }

    public func peer(for id: PeerID) throws -> PairedPeer? {
        try load()[id]
    }

    public func save(_ peer: PairedPeer) throws {
        var peers = try load()
        peers[peer.id] = peer
        try write(peers)
    }

    public func remove(_ id: PeerID) throws {
        var peers = try load()
        guard peers.removeValue(forKey: id) != nil else { return }
        try write(peers)
    }

    private func load() throws -> [PeerID: PairedPeer] {
        guard let data = try backend.read(service: service, account: Self.account) else { return [:] }
        let list: [PairedPeer]
        do {
            list = try JSONDecoder().decode([PairedPeer].self, from: data)
        } catch {
            throw PairedPeerStoreError.corrupted
        }
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    private func write(_ peers: [PeerID: PairedPeer]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let list = peers.values.sorted { $0.id < $1.id }
        try backend.upsert(service: service, account: Self.account, data: encoder.encode(list))
    }
}
