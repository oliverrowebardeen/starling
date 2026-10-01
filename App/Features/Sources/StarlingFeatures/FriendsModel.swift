import Foundation
import Observation
import StarlingCore

/// The paired friends list. Reads come from the `PairedPeerStore`; changes
/// go through the app's functions, never straight to the store. Lane E1
/// orders every pin change through one `PinAuthority`, so an unpair must go
/// through it to end the friend's sessions on every link (docs/requests/
/// E1.md item 2.7), and a direct store write could re-add a removed pin.
@MainActor
@Observable
public final class FriendsModel {
    public private(set) var friends: [PairedPeer] = []
    public private(set) var isLoaded = false
    public private(set) var notice: String?
    /// Friends with a live secure session right now, from the Inbox loop.
    public private(set) var reachable: Set<PeerID> = []

    private let store: any PairedPeerStore
    private let unpair: @Sendable (PeerID) async throws -> Void
    private let renameFriend: (@Sendable (PeerID, String) async throws -> Void)?

    /// - Parameters:
    ///   - unpair: Ends the friend's sessions and removes the pin (lane E1's
    ///     `PinAuthority.unpair`).
    ///   - rename: Changes a nickname, or nil when the build has no safe way
    ///     to (lane E1 has no rename through the authority yet).
    public init(
        store: any PairedPeerStore,
        unpair: @escaping @Sendable (PeerID) async throws -> Void,
        rename: (@Sendable (PeerID, String) async throws -> Void)? = nil
    ) {
        self.store = store
        self.unpair = unpair
        renameFriend = rename
    }

    public var canRename: Bool { renameFriend != nil }

    /// A warning when `nickname` matches or looks like another friend's
    /// (issue #46). The owner may keep it anyway.
    public func nicknameWarning(_ nickname: String, for id: PeerID) -> String? {
        NicknameCheck.warning(for: nickname, among: friends, excluding: id)
    }

    public func isReachable(_ id: PeerID) -> Bool { reachable.contains(id) }

    public func load() async {
        do {
            friends = try await store.all()
            notice = nil
        } catch {
            notice = "Your friends couldn't be loaded."
        }
        isLoaded = true
    }

    /// Connection changes from the app's Inbox loop.
    public func handle(_ event: InboxEvent) {
        switch event {
        case .peerAvailable(let peer): reachable.insert(peer)
        case .peerUnavailable(let peer): reachable.remove(peer)
        case .message, .dropped: break
        }
    }

    /// Nicknames stay on this phone; renaming never tells the friend.
    public func rename(_ id: PeerID, to nickname: String) async -> Bool {
        guard let renameFriend, friends.contains(where: { $0.id == id }) else { return false }
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...PairedPeer.maxNicknameCharacters).contains(trimmed.count) else {
            notice = "Use 1 to \(PairedPeer.maxNicknameCharacters) characters."
            return false
        }
        do {
            try await renameFriend(id, trimmed)
            await load()
            return true
        } catch {
            notice = "Couldn't rename. Try again."
            return false
        }
    }

    /// Unpairs the friend everywhere. Pairing again needs both people together.
    /// A failure stays on screen after the list refreshes: the friend is
    /// still trusted, and the owner must not think otherwise.
    public func remove(_ id: PeerID) async {
        let name = friends.first { $0.id == id }?.nickname ?? "This friend"
        do {
            try await unpair(id)
            reachable.remove(id)
            await load()
        } catch {
            await load()
            notice = "Couldn't unpair \(name). They are still paired. Try again."
        }
    }
}
