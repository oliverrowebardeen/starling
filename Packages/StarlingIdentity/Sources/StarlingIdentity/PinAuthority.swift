import Foundation
import StarlingCore
import Synchronization

/// Why `PinAuthority.rename` refused.
public enum PinAuthorityError: Error, Hashable, Sendable {
    /// No pin is stored for the peer.
    case notPinned
    /// An unpair of the peer is in progress.
    case unpairInProgress
    /// A failed delete left the peer quarantined; unpair it again.
    case quarantined
}

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

    /// One revocation observer and its delivery queue. Each observer has at
    /// most one delivery task at a time, draining `pending`, which keeps only
    /// the latest epoch per peer (issue #40).
    private struct Observer {
        let handler: @Sendable (PeerID, UInt64) async -> Void
        var pending: [PeerID: UInt64] = [:]
        var delivering = false
    }

    private struct State {
        var epochs: GenerationTable
        /// Only peers with something in progress or quarantined have an entry.
        var flags: [PeerID: Flags] = [:]
        var locked = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var observers: [Observer] = []

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

    /// Registers a handler run after every revocation and rollback, in its
    /// own task and never awaited by the revocation. For liveness only
    /// (ending sessions promptly, cancelling ceremonies): correctness rests
    /// on the per-frame epoch check.
    public func observeRevocations(_ handler: @escaping @Sendable (PeerID, UInt64) async -> Void) {
        state.withLock { $0.observers.append(Observer(handler: handler)) }
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
        let epoch = markRevoked(peer)
        notifyObservers(peer, epoch: epoch)
    }

    /// `revoke`'s synchronous half: the epoch moves. Never awaits. Returns
    /// the epoch the revocation produced.
    @discardableResult
    func markRevoked(_ peer: PeerID) -> UInt64 {
        state.withLock {
            $0.epochs.bump(peer)
            return $0.epochs.value(of: peer)
        }
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
    /// The only thing it awaits is Keychain I/O: observers are notified
    /// afterwards and not awaited, because a ceremony's cancel notice is a
    /// network send that can stall (issue #32).
    func completeRemoval(_ peer: PeerID) async throws {
        do {
            try await serialized { try await self.store.remove(peer) }
        } catch {
            notifyObservers(peer, epoch: endRemoval(peer, deleted: false))
            throw error
        }
        notifyObservers(peer, epoch: endRemoval(peer, deleted: true))
    }

    /// Ends a removal and returns the epoch it produced.
    private func endRemoval(_ peer: PeerID, deleted: Bool) -> UInt64 {
        state.withLock {
            $0.epochs.bump(peer)
            $0.update(peer) {
                $0.removing -= 1
                $0.quarantined = !deleted
            }
            return $0.epochs.value(of: peer)
        }
    }

    /// Tells every observer about a revocation of `peer` without waiting for
    /// them, one task per observer so a stalled one cannot hold up another.
    /// Observers are for liveness only (ending sessions promptly, cancelling
    /// ceremonies), so nothing a revocation guarantees waits on them.
    ///
    /// Each observer gets the epoch the revocation produced, so it can clean
    /// up only what was authenticated or started under an older epoch and
    /// leave anything newer alone, however late the notice arrives.
    ///
    /// Notices coalesce (issue #40): each observer has at most one delivery
    /// task, and while it is busy, newer notices for a peer replace older
    /// ones. Epochs only move forward, so the latest one carries everything an
    /// older one would, and an observer that stalls holds one suspended task
    /// and at most one pending notice per peer, however many revocations
    /// happen meanwhile.
    func notifyObservers(_ peer: PeerID, epoch: UInt64) {
        let starting = state.withLock { state -> [Int] in
            var starting: [Int] = []
            for index in state.observers.indices {
                state.observers[index].pending[peer] = max(state.observers[index].pending[peer] ?? 0, epoch)
                if !state.observers[index].delivering {
                    state.observers[index].delivering = true
                    starting.append(index)
                }
            }
            return starting
        }
        for index in starting { Task { await self.deliver(to: index) } }
    }

    /// The single delivery task for one observer: takes one pending notice
    /// at a time until none is left.
    private func deliver(to index: Int) async {
        while true {
            let next = state.withLock { state -> (@Sendable (PeerID, UInt64) async -> Void, PeerID, UInt64)? in
                guard let (peer, epoch) = state.observers[index].pending.first else {
                    state.observers[index].delivering = false
                    return nil
                }
                state.observers[index].pending[peer] = nil
                return (state.observers[index].handler, peer, epoch)
            }
            guard let (handler, peer, epoch) = next else { return }
            await handler(peer, epoch)
        }
    }

    /// Notices waiting for delivery across all observers, for tests.
    var pendingNoticeCount: Int { state.withLock { $0.observers.reduce(0) { $0 + $1.pending.count } } }

    // MARK: Pairing

    private enum CommitResult: Sendable { case refused, committed, rolledBack(epoch: UInt64) }

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
            do {
                try await self.store.remove(id)
            } catch {
                _ = self.endRollback(id, deleted: false)
                throw error
            }
            return .rolledBack(epoch: self.endRollback(id, deleted: true))
        }
        switch result {
        case .committed: return true
        case .refused: return false
        case .rolledBack(let epoch):
            notifyObservers(id, epoch: epoch)
            return false
        }
    }

    /// Ends a rollback: the epoch moves again, the commit ends, and a failed
    /// delete quarantines the peer. Returns the epoch it produced.
    private func endRollback(_ peer: PeerID, deleted: Bool) -> UInt64 {
        state.withLock {
            $0.epochs.bump(peer)
            $0.update(peer) {
                $0.committing -= 1
                $0.quarantined = !deleted
            }
            return $0.epochs.value(of: peer)
        }
    }

    // MARK: Renaming

    /// Changes a pinned friend's nickname, and nothing else: the key, the
    /// ID, and the pairing date stay. This is the only safe way to rename.
    /// It runs under the pin lock like commits and unpairs, and refuses a
    /// peer that is being unpaired, is quarantined, or is no longer pinned,
    /// so it can never write back a pin an unpair removed. An unpair that
    /// begins during the save deletes the pin after it (ADR 0100 decision 11).
    /// The nickname is validated as `PairedPeer` does and never leaves the device.
    public func rename(_ peer: PeerID, to nickname: String) async throws {
        try checkRenamable(peer)
        try await serialized {
            try self.checkRenamable(peer)
            guard let current = try await self.store.peer(for: peer), current.id == peer else {
                throw PinAuthorityError.notPinned
            }
            let renamed = try PairedPeer(publicKey: current.publicKey, nickname: nickname, pairedAt: current.pairedAt)
            // An unpair may have begun while the pin was read. Its delete waits
            // for this lock, but do not write a pin it is about to remove.
            try self.checkRenamable(peer)
            try await self.store.save(renamed)
        }
    }

    private func checkRenamable(_ peer: PeerID) throws {
        let flags = state.withLock { $0.flags[peer] }
        if flags?.quarantined == true { throw PinAuthorityError.quarantined }
        if (flags?.removing ?? 0) > 0 { throw PinAuthorityError.unpairInProgress }
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
