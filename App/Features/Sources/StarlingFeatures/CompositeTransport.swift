import StarlingCore

/// One `Transport` over several links, so the app keeps a single `Outbox`
/// and `Inbox` while lane E1 gives it one `SecureTransport` per link
/// (LocalP2P and Wi-Fi Aware, docs/requests/E1.md item 2).
///
/// A peer is announced when the first link reports it and lost only when no
/// link has it. A send goes to a link where the peer is available, most
/// recently announced first, and fails over to the next if one refuses.
/// Every link must share this device's `localPeer`.
public actor CompositeTransport: Transport {
    /// The first link's kind. Nothing in StarlingKit decides on the kind;
    /// it is a label.
    public nonisolated let kind: TransportKind
    public nonisolated let localPeer: PeerID
    public nonisolated let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let links: [any Transport]
    /// Indexes of the links each peer is available on, newest last.
    private var availability: [PeerID: [Int]] = [:]
    private var pumps: [Task<Void, Never>] = []

    public init(links: [any Transport]) {
        precondition(!links.isEmpty, "a composite needs at least one link")
        precondition(Set(links.map(\.localPeer)).count == 1, "every link must use this device's PeerID")
        self.links = links
        kind = links[0].kind
        localPeer = links[0].localPeer
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    /// Starts every link. Throws only if none of them could start.
    public func start() async throws {
        if pumps.isEmpty {
            for (index, link) in links.enumerated() {
                let events = link.events
                pumps.append(Task { [weak self] in
                    for await event in events { await self?.handle(event, on: index) }
                })
            }
        }
        var failure: (any Error)?
        var started = 0
        for link in links {
            do {
                try await link.start()
                started += 1
            } catch {
                failure = failure ?? error
            }
        }
        if started == 0, let failure { throw failure }
    }

    public func send(_ frame: Frame, to peer: PeerID) async throws {
        let candidates = (availability[peer] ?? []).reversed()
        guard !candidates.isEmpty else { throw TransportError.peerUnreachable(peer) }
        var lastError: (any Error)?
        for index in candidates {
            do {
                try await links[index].send(frame, to: peer)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? TransportError.peerUnreachable(peer)
    }

    public func stop() async {
        for link in links { await link.stop() }
        for pump in pumps { pump.cancel() }
        pumps = []
        availability = [:]
        continuation.finish()
    }

    private func handle(_ event: TransportEvent, on index: Int) {
        switch event {
        case .peerAvailable(let peer):
            let wasAvailable = !(availability[peer] ?? []).isEmpty
            availability[peer, default: []].removeAll { $0 == index }
            availability[peer, default: []].append(index)
            if !wasAvailable { continuation.yield(event) }
        case .peerUnavailable(let peer):
            guard var links = availability[peer], links.contains(index) else { return }
            links.removeAll { $0 == index }
            availability[peer] = links.isEmpty ? nil : links
            if links.isEmpty { continuation.yield(event) }
        case .received:
            continuation.yield(event)
        }
    }
}
