import StarlingCore

/// Wraps a raw link (before lane E1's `SecureTransport`) and records which
/// peers it reports, passing every event through unchanged.
///
/// The pairing screen needs the key-derived `PeerID` of a nearby phone that
/// is not pinned yet, and nothing public reports one: `SecureTransport`
/// announces pinned peers only, and `PairingService` keeps the pairing
/// link's events to itself (docs/requests/H.md request 5). A raw link's
/// `PeerID` is the claim from its link hello; pairing proves the key behind
/// it (ADR 0003), so the app only uses it to offer a choice.
public actor LinkWatcher: Transport {
    public nonisolated let kind: TransportKind
    public nonisolated let localPeer: PeerID
    public nonisolated let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let inner: any Transport
    private var reachable: Set<PeerID> = []
    private var pump: Task<Void, Never>?

    public init(wrapping inner: any Transport) {
        self.inner = inner
        kind = inner.kind
        localPeer = inner.localPeer
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    /// Peers the link currently reports, pinned or not.
    public func reachablePeers() -> Set<PeerID> { reachable }

    public func start() async throws {
        if pump == nil {
            let events = inner.events
            pump = Task { [weak self] in
                for await event in events { await self?.forward(event) }
                await self?.finish()
            }
        }
        try await inner.start()
    }

    public func send(_ frame: Frame, to peer: PeerID) async throws {
        try await inner.send(frame, to: peer)
    }

    public func stop() async {
        await inner.stop()
        pump?.cancel()
        pump = nil
        finish()
    }

    private func forward(_ event: TransportEvent) {
        switch event {
        case .peerAvailable(let peer): reachable.insert(peer)
        case .peerUnavailable(let peer): reachable.remove(peer)
        case .received: break
        }
        continuation.yield(event)
    }

    private func finish() {
        reachable = []
        continuation.finish()
    }
}
