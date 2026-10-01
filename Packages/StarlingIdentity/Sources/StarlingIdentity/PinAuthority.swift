import Foundation
import StarlingCore
import Synchronization

/// The one authority over pinned keys: every pin mutation (a pairing
/// commit, an unpair) and every pin use (a handshake's lookup) goes through
/// it, so unpairing is ordered against all of them (ADR 0100 decision 11).
///
/// Invariant: once `beginRemoval(_:)` has run for a peer, no pin for that
/// peer survives the removal, and no lookup that overlaps it returns a pin.
///
/// - A revocation takes its mark synchronously, before any await: it moves
///   the peer's revocation token, and an unpair also marks a removal in
///   progress until the pin is gone.
/// - Pairing commits and removals run one at a time under one lock. A commit
///   saves only if the token has not moved since its ceremony started, and
///   checks again after the save; if it moved, the commit removes the pin
///   before releasing the lock.
/// - A lookup returns nothing while a removal is in progress, and discards
///   what it read if the token moved. A pin a commit is about to undo exists
///   only while the removal mark is set, so no lookup can return it.
public final class PinAuthority: Sendable {
    public let store: any PairedPeerStore

    private struct State {
        var tokens: [PeerID: UInt64] = [:]
        var removing: [PeerID: Int] = [:]
        var locked = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var observers: [@Sendable (PeerID) async -> Void] = []
    }

    private let state = Mutex(State())

    public init(store: any PairedPeerStore) {
        self.store = store
    }

    // MARK: Revocation tokens

    /// Moves every time `peer` is revoked. A ceremony records it when it
    /// starts and commits only if it has not moved.
    public func revocationToken(of peer: PeerID) -> UInt64 {
        state.withLock { $0.tokens[peer, default: 0] }
    }

    /// Whether an unpair of `peer` is still removing its pin.
    public func isRemoving(_ peer: PeerID) -> Bool {
        state.withLock { $0.removing[peer, default: 0] > 0 }
    }

    /// Registers a handler run on every revocation, before an unpair removes
    /// the pin. `SecureTransport` ends sessions; `PairingService` ends ceremonies.
    public func observeRevocations(_ handler: @escaping @Sendable (PeerID) async -> Void) {
        state.withLock { $0.observers.append(handler) }
    }

    // MARK: Unpairing

    /// Unpairs `peer`: marks it revoked, tells every observer, and removes
    /// the pin. Prefer `SecureTransport.unpair(_:)`, which also ends the
    /// session synchronously, before its first await.
    public func unpair(_ peer: PeerID) async throws {
        beginRemoval(peer)
        try await completeRemoval(peer)
    }

    /// Revokes `peer` without removing its pin: moves the token (so running
    /// ceremonies cannot commit) and tells every observer.
    public func revoke(_ peer: PeerID) async {
        markRevoked(peer)
        await notifyObservers(peer)
    }

    /// The synchronous half of a revocation. Never awaits.
    func markRevoked(_ peer: PeerID) {
        state.withLock { $0.tokens[peer, default: 0] += 1 }
    }

    /// The synchronous half of an unpair: the revocation mark plus a removal
    /// in progress, so lookups refuse the pin from now on. Never awaits.
    func beginRemoval(_ peer: PeerID) {
        state.withLock {
            $0.tokens[peer, default: 0] += 1
            $0.removing[peer, default: 0] += 1
        }
    }

    /// The asynchronous half of an unpair. Ends the removal mark even if
    /// the store throws; the caller sees the error.
    func completeRemoval(_ peer: PeerID) async throws {
        defer {
            state.withLock {
                $0.removing[peer, default: 1] -= 1
                if $0.removing[peer] == 0 { $0.removing[peer] = nil }
            }
        }
        await notifyObservers(peer)
        try await serialized { try await self.store.remove(peer) }
    }

    func notifyObservers(_ peer: PeerID) async {
        let observers = state.withLock { $0.observers }
        for observer in observers { await observer(peer) }
    }

    // MARK: Pairing

    /// Saves `peer` if it has not been revoked since `token` was read, and
    /// leaves no pin if a revocation starts before the commit ends, even if
    /// the save already landed. Returns whether the pin was committed.
    func commit(_ peer: PairedPeer, ifNotRevokedSince token: UInt64) async throws -> Bool {
        try await serialized {
            guard self.revocationToken(of: peer.id) == token, !self.isRemoving(peer.id) else { return false }
            try await self.store.save(peer)
            guard self.revocationToken(of: peer.id) == token else {
                try await self.store.remove(peer.id)
                return false
            }
            return true
        }
    }

    // MARK: Lookups

    /// The pin for `peer` and the token it was read under, or nil while an
    /// unpair is removing it or if a revocation moved the token meanwhile.
    /// Callers that resume later must check the token again before use.
    func pinned(_ peer: PeerID) async -> (PairedPeer, UInt64)? {
        let token = revocationToken(of: peer)
        guard !isRemoving(peer), let paired = try? await store.peer(for: peer), paired.id == peer,
              !isRemoving(peer), revocationToken(of: peer) == token
        else { return nil }
        return (paired, token)
    }

    // MARK: Lock

    /// Runs `operation` while holding the pin lock. Commits and removals
    /// therefore never interleave, whatever they await.
    private func serialized<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let acquired = state.withLock { state -> Bool in
                guard state.locked else {
                    state.locked = true
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if acquired { continuation.resume() }
        }
    }

    private func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.locked = false
                return nil
            }
            // The lock passes straight to the next waiter.
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}
