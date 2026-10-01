import Foundation
import Observation
import StarlingCore

/// The paired friends list, backed by a `PairedPeerStore`.
@MainActor
@Observable
public final class FriendsModel {
    public private(set) var friends: [PairedPeer] = []
    public private(set) var isLoaded = false
    public private(set) var notice: String?

    private let store: any PairedPeerStore

    public init(store: any PairedPeerStore) {
        self.store = store
    }

    public func load() async {
        do {
            friends = try await store.all()
            notice = nil
        } catch {
            notice = "Your friends couldn't be loaded."
        }
        isLoaded = true
    }

    /// Nicknames stay on this phone; renaming never tells the friend.
    public func rename(_ id: PeerID, to nickname: String) async -> Bool {
        guard let peer = friends.first(where: { $0.id == id }) else { return false }
        do {
            try await store.save(try PairedPeer(publicKey: peer.publicKey, nickname: nickname, pairedAt: peer.pairedAt))
            await load()
            return true
        } catch is ValidationError {
            notice = "Use 1 to \(PairedPeer.maxNicknameCharacters) characters."
            return false
        } catch {
            notice = "Couldn't rename. Try again."
            return false
        }
    }

    /// Forgets the friend's pinned key. Pairing again needs both people together.
    /// A failure stays on screen after the list refreshes: the friend is
    /// still trusted, and the owner must not think otherwise.
    public func remove(_ id: PeerID) async {
        let name = friends.first { $0.id == id }?.nickname ?? "This friend"
        do {
            try await store.remove(id)
            await load()
        } catch {
            await load()
            notice = "Couldn't unpair \(name). They are still paired. Try again."
        }
    }
}
