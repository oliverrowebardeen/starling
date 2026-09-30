import Foundation
import StarlingCore

/// An in-memory `PairedPeerStore` for tests and previews.
public actor InMemoryPairedPeerStore: PairedPeerStore {
    private var peers: [PeerID: PairedPeer]

    public init(_ peers: [PairedPeer] = []) {
        self.peers = Dictionary(peers.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func all() async throws -> [PairedPeer] {
        peers.values.sorted { $0.pairedAt < $1.pairedAt }
    }

    public func peer(for id: PeerID) async throws -> PairedPeer? { peers[id] }

    public func save(_ peer: PairedPeer) async throws { peers[peer.id] = peer }

    public func remove(_ id: PeerID) async throws { peers[id] = nil }
}

/// A pairing ceremony that shows `code`, then succeeds with `peer` if the
/// owner confirms the codes match, or fails with `.codeMismatch` if not.
public actor ScriptedPairingSession: PairingSession {
    public nonisolated let events: AsyncStream<PairingEvent>
    private let continuation: AsyncStream<PairingEvent>.Continuation
    private let peer: PairedPeer
    private var finished = false

    public init(code: String, peer: PairedPeer) {
        self.peer = peer
        (events, continuation) = AsyncStream.makeStream(of: PairingEvent.self)
        continuation.yield(.confirmCode(code))
    }

    public func confirm(codesMatch: Bool) async {
        finish(codesMatch ? .paired(peer) : .failed(.codeMismatch))
    }

    public func cancel() async {
        finish(.failed(.cancelled))
    }

    private func finish(_ event: PairingEvent) {
        guard !finished else { return }
        finished = true
        continuation.yield(event)
        continuation.finish()
    }
}
