import Foundation
import StarlingCore
import Synchronization

/// The one authority over a device's pinned keys (ADR 0100 decision 11).
///
/// It is identity-scoped: the app creates one per identity and store and
/// injects it into every `SecureTransport` and `PairingService`. Every pin
/// mutation (a pairing commit, an unpair) and every pin use (a handshake's
/// lookup) goes through it.
///
/// All revocation state sits behind one `Mutex`, so every check and update
/// is atomic and has no suspension point; only Keychain I/O is async. Per
/// peer it keeps an epoch that only moves forward, plus counts of unpairs
/// and commits in progress and a quarantine flag. Sessions are stamped with
/// the epoch they were authenticated under, and transports check that stamp
/// against `epoch(of:)` on every frame, so moving the epoch kills every
/// session with the peer on every transport at once.
///
/// The epoch moves at the start of every revocation (before any await), at
/// the end of every unpair, and on every commit rollback. Lookups are
/// refused while an unpair or a commit for the peer is in progress, or while
/// it is quarantined after a failed delete.
public final class PinAuthority: Sendable {
    public let identity: IdentityKeyPair
    public let store: any PairedPeerStore

    private struct Flags {
        var removing = 0
        var committing = 0
        var quarantined = false
        var isClear: Bool { removing == 0 && committing == 0 && !quarantined }
    }

    private struct State {
        var epochs: GenerationTable
        /// Only peers with something in progress or quarantined have an entry.
        var flags: [PeerID: Flags] = [:]
        var locked = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var observers: [@Sendable (PeerID) async -> Void] = []

        func blocked(_ peer: PeerID) -> Bool { !(flags[peer]?.isClear ?? true) }

        mutating func update(_ peer: PeerID, _ change: (inout Flags) -> Void) {
            var entry = flags[peer] ?? Flags()
            change(&entry)
            flags[peer] = entry.isClear ? nil : entry
        }
    }

    private let state: Mutex<State>

    /// Named points where a test can act synchronously, to reproduce an
    /// interleaving deterministically (for example: another transport bumps
    /// the epoch exactly here). Nil in production; reaching one never awaits
    /// and never holds the state mutex.
    enum Checkpoint: Sendable, Equatable {
        /// `epoch(of:)` has read the peer's epoch and released the mutex.
        case epochRead(PeerID)
        /// A commit has decided, after its save, whether it stands.
        case commitDecided(PeerID)
    }

    private let checkpointHandler = Mutex<(@Sendable (Checkpoint) -> Void)?>(nil)

    /// Installs (or with nil, removes) the test checkpoint handler.
    func onCheckpoint(_ handler: (@Sendable (Checkpoint) -> Void)?) {
        checkpointHandler.withLock { $0 = handler }
    }

    private func reach(_ checkpoint: Checkpoint) {
        let handler = checkpointHandler.withLock { $0 }
        handler?(checkpoint)
    }

    /// - Parameter capacity: Most peers whose epochs are kept; older ones are
    ///   evicted safely (see `GenerationTable`).
    public init(identity: IdentityKeyPair, store: any PairedPeerStore, capacity: Int = 1_024) {
        self.identity = identity
        self.store = store
        state = Mutex(State(epochs: GenerationTable(capacity: capacity)))
    }

    // MARK: Reading the state

    /// The peer's current epoch. A session is usable only while the epoch it
    /// was authenticated under equals this.
    public func epoch(of peer: PeerID) -> UInt64 {
        let epoch = state.withLock { $0.epochs.value(of: peer) }
        reach(.epochRead(peer))
        return epoch
    }

    /// Runs `body` only if `peer`'s epoch is still `epoch`, inside the state
    /// mutex, so no revocation on any transport can begin between the check
    /// and `body` (ADR 0100 decision 11). Returns nil, without running
    /// `body`, if the epoch moved. `body` must be short and synchronous and
    /// must not call back into the authority, which would deadlock.
    func ifCurrent<T: Sendable>(_ peer: PeerID, epoch: UInt64, _ body: () throws -> T) throws -> T? {
        try state.withLock { state throws -> T? in
            guard state.epochs.value(of: peer) == epoch else { return nil }
            return try body()
        }
    }

    /// Whether lookups for `peer` are refused: an unpair or a commit is in
    /// progress, or a failed delete left it quarantined.
    public func isBlocked(_ peer: PeerID) -> Bool {
        state.withLock { $0.blocked(peer) }
    }

    /// How many epochs are kept, for tests.
    var trackedTokenCount: Int { state.withLock { $0.epochs.count } }

    /// Registers a handler run after every revocation and rollback. For
    /// liveness only (ending sessions promptly, cancelling ceremonies):
    /// correctness rests on the per-frame epoch check.
    public func observeRevocations(_ handler: @escaping @Sendable (PeerID) async -> Void) {
        state.withLock { $0.observers.append(handler) }
    }

    // MARK: Revoking

    /// Unpairs `peer`. Prefer `SecureTransport.unpair(_:)`, which also ends
    /// that transport's sessions in the same synchronous step.
    public func unpair(_ peer: PeerID) async throws {
        beginRemoval(peer)
        try await completeRemoval(peer)
    }

    /// Revokes `peer` without removing its pin.
    public func revoke(_ peer: PeerID) async {
        markRevoked(peer)
        await notifyObservers(peer)
    }

    /// `revoke`'s synchronous half: the epoch moves. Never awaits.
    func markRevoked(_ peer: PeerID) {
        state.withLock { $0.epochs.bump(peer) }
    }

    /// `unpair`'s synchronous half: the epoch moves and a removal is in
    /// progress, so lookups are refused from now on. Never awaits.
    func beginRemoval(_ peer: PeerID) {
        state.withLock {
            $0.epochs.bump(peer)
            $0.update(peer) { $0.removing += 1 }
        }
    }

    /// `unpair`'s asynchronous half. Deletes the pin under the pin lock, then
    /// moves the epoch again and ends the removal. If the delete fails, the
    /// peer stays quarantined (lookups refused) and the error is rethrown.
    func completeRemoval(_ peer: PeerID) async throws {
        await notifyObservers(peer)
        do {
            try await serialized { try await self.store.remove(peer) }
        } catch {
            endRemoval(peer, deleted: false)
            throw error
        }
        endRemoval(peer, deleted: true)
    }

    private func endRemoval(_ peer: PeerID, deleted: Bool) {
        state.withLock {
            $0.epochs.bump(peer)
            $0.update(peer) {
                $0.removing -= 1
                $0.quarantined = !deleted
            }
        }
    }

    func notifyObservers(_ peer: PeerID) async {
        let observers = state.withLock { $0.observers }
        for observer in observers { await observer(peer) }
    }

    // MARK: Pairing

    private enum CommitResult: Sendable { case refused, committed, rolledBack }

    /// Saves `peer` if its epoch is still `epoch` (read when the ceremony
    /// started) and nothing is removing or quarantining it. If the epoch
    /// moves before the commit ends, the save is rolled back: the pin is
    /// deleted and the epoch moves again, killing anything authenticated
    /// meanwhile. Returns whether the pin was committed.
    func commit(_ peer: PairedPeer, ifEpochIs epoch: UInt64) async throws -> Bool {
        let id = peer.id
        let result: CommitResult = try await serialized {
            let admitted = self.state.withLock { state -> Bool in
                guard state.epochs.value(of: id) == epoch, !state.blocked(id) else { return false }
                state.update(id) { $0.committing += 1 }
                return true
            }
            guard admitted else { return .refused }
            do {
                try await self.store.save(peer)
            } catch {
                self.state.withLock { $0.update(id) { $0.committing -= 1 } }
                throw error
            }
            // One section decides and, if the save stands, ends the commit, so
            // no revocation can start between the decision and the end. If the
            // epoch moved, the commit stays in progress (lookups refused) until
            // the rollback below ends it.
            let stands = self.state.withLock { state -> Bool in
                guard state.epochs.value(of: id) == epoch else { return false }
                state.update(id) { $0.committing -= 1 }
                return true
            }
            self.reach(.commitDecided(id))
            guard !stands else { return .committed }
            // Roll back. The commit stays in progress (lookups refused) until
            // the delete is done; if it fails, the peer is quarantined.
            var deleted = false
            defer {
                self.state.withLock {
                    $0.epochs.bump(id)
                    $0.update(id) {
                        $0.committing -= 1
                        $0.quarantined = !deleted
                    }
                }
            }
            try await self.store.remove(id)
            deleted = true
            return .rolledBack
        }
        if result == .rolledBack { await notifyObservers(id) }
        return result == .committed
    }

    // MARK: Lookups

    /// The pin for `peer` and the epoch it was read under, or nil while the
    /// peer is blocked or if the epoch moved during the read. Sessions built
    /// on the result must be stamped with that epoch.
    func pinned(_ peer: PeerID) async -> (PairedPeer, UInt64)? {
        let epoch: UInt64? = state.withLock { $0.blocked(peer) ? nil : $0.epochs.value(of: peer) }
        guard let epoch, let paired = try? await store.peer(for: peer), paired.id == peer else { return nil }
        let unchanged = state.withLock { !$0.blocked(peer) && $0.epochs.value(of: peer) == epoch }
        return unchanged ? (paired, epoch) : nil
    }

    // MARK: Pin lock

    /// Runs `operation` while holding the pin lock, which serializes every
    /// Keychain write (commits and removals).
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
