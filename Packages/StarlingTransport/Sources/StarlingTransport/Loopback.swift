import Foundation
import StarlingCore

/// An in-memory network for tests and the simulator.
///
/// Every `LoopbackTransport` joined to a hub can reach every other one unless
/// the link is partitioned. Frames between a pair arrive in the order they
/// were sent. The hub can also inject frames with a forged sender, which is
/// what a malicious peer on an unauthenticated link can do.
public actor LoopbackHub {
    /// One frame as it crossed the hub, for observers.
    public struct Delivery: Hashable, Sendable {
        public let frame: Frame
        public let from: PeerID
        public let to: PeerID
    }

    private struct Link: Hashable {
        let low: PeerID
        let high: PeerID
        init(_ a: PeerID, _ b: PeerID) { (low, high) = a < b ? (a, b) : (b, a) }
    }

    private let latency: Duration
    private var members: [PeerID: LoopbackTransport] = [:]
    private var partitioned: Set<Link> = []
    private var observers: [AsyncStream<Delivery>.Continuation] = []

    /// - Parameter latency: Delay applied to every frame, awaited by the sender.
    public init(latency: Duration = .zero) {
        self.latency = latency
    }

    public var peers: [PeerID] { members.keys.sorted() }

    /// A stream of every frame routed through the hub, including injected ones.
    public func deliveries() -> AsyncStream<Delivery> {
        let (stream, continuation) = AsyncStream.makeStream(of: Delivery.self)
        observers.append(continuation)
        return stream
    }

    /// Cuts the link between two peers, as if they walked out of range.
    public func partition(_ a: PeerID, _ b: PeerID) async {
        guard partitioned.insert(Link(a, b)).inserted else { return }
        await members[a]?.deliver(.peerUnavailable(b))
        await members[b]?.deliver(.peerUnavailable(a))
    }

    public func heal(_ a: PeerID, _ b: PeerID) async {
        guard partitioned.remove(Link(a, b)) != nil else { return }
        await members[a]?.deliver(.peerAvailable(b))
        await members[b]?.deliver(.peerAvailable(a))
    }

    /// Delivers `frame` to `recipient` as if `claimedSender` sent it. Loopback
    /// links are unauthenticated, like every Phase 0 transport.
    public func inject(_ frame: Frame, claimedSender: PeerID, to recipient: PeerID) async throws {
        try await route(frame, from: claimedSender, to: recipient)
    }

    func join(_ transport: LoopbackTransport) async {
        let newcomer = transport.localPeer
        members[newcomer] = transport
        for (peer, member) in members where peer != newcomer && !partitioned.contains(Link(peer, newcomer)) {
            await member.deliver(.peerAvailable(newcomer))
            await transport.deliver(.peerAvailable(peer))
        }
    }

    func leave(_ leaving: PeerID) async {
        guard members.removeValue(forKey: leaving) != nil else { return }
        for (peer, member) in members where !partitioned.contains(Link(peer, leaving)) {
            await member.deliver(.peerUnavailable(leaving))
        }
    }

    func route(_ frame: Frame, from sender: PeerID, to recipient: PeerID) async throws {
        guard let target = members[recipient], !partitioned.contains(Link(sender, recipient)) else {
            throw TransportError.peerUnreachable(recipient)
        }
        if latency > .zero { try await Task.sleep(for: latency) }
        await target.deliver(.received(frame, from: sender))
        for observer in observers { observer.yield(Delivery(frame: frame, from: sender, to: recipient)) }
    }
}

/// A `Transport` backed by a `LoopbackHub`. Build this first for any test.
public actor LoopbackTransport: Transport {
    private enum State { case idle, started, stopped }

    public nonisolated let kind = TransportKind.loopback
    public nonisolated let localPeer: PeerID
    public nonisolated let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let hub: LoopbackHub
    private var state = State.idle

    public init(localPeer: PeerID = .random(), hub: LoopbackHub) {
        self.localPeer = localPeer
        self.hub = hub
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    public func start() async throws {
        switch state {
        case .started: return
        case .stopped: throw TransportError.stopped
        case .idle:
            state = .started
            await hub.join(self)
        }
    }

    public func send(_ frame: Frame, to peer: PeerID) async throws {
        switch state {
        case .idle: throw TransportError.notStarted
        case .stopped: throw TransportError.stopped
        case .started: try await hub.route(frame, from: localPeer, to: peer)
        }
    }

    public func stop() async {
        guard state != .stopped else { return }
        let wasStarted = state == .started
        state = .stopped
        if wasStarted { await hub.leave(localPeer) }
        continuation.finish()
    }

    func deliver(_ event: TransportEvent) {
        guard state == .started else { return }
        continuation.yield(event)
    }
}
