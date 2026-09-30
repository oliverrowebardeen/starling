import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingIdentity
import StarlingTransport
import Testing

struct TimedOut: Error, CustomStringConvertible {
    let description: String
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(
    _ what: String, timeout: Duration = .seconds(5),
    _ condition: @Sendable () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TimedOut(description: "timed out waiting for \(what)")
}

/// Records every value of a stream so tests can assert on history.
actor Recorder<Element: Sendable> {
    private(set) var values: [Element] = []
    private var task: Task<Void, Never>?

    init() {}

    static func recording(_ stream: AsyncStream<Element>) async -> Recorder<Element> {
        let recorder = Recorder<Element>()
        await recorder.consume(stream)
        return recorder
    }

    private func consume(_ stream: AsyncStream<Element>) {
        task = Task { [weak self] in
            for await value in stream { await self?.append(value) }
        }
    }

    private func append(_ value: Element) { values.append(value) }
}

extension Recorder where Element == TransportEvent {
    var received: [(Data, PeerID)] {
        values.compactMap { if case .received(let frame, let from) = $0 { (frame.bytes, from) } else { nil } }
    }

    func count(_ event: TransportEvent) -> Int { values.filter { $0 == event }.count }
    func contains(_ event: TransportEvent) -> Bool { values.contains(event) }
}

/// A Loopback link that can hold outbound frames and release them in any
/// order: a network attacker who delays and reorders.
actor InterceptingLink: Transport {
    nonisolated let inner: LoopbackTransport
    nonisolated var kind: TransportKind { inner.kind }
    nonisolated var localPeer: PeerID { inner.localPeer }
    nonisolated var events: AsyncStream<TransportEvent> { inner.events }

    private var holding = false
    private(set) var held: [(Frame, PeerID)] = []

    init(_ inner: LoopbackTransport) { self.inner = inner }

    func start() async throws { try await inner.start() }
    func stop() async { await inner.stop() }

    func send(_ frame: Frame, to peer: PeerID) async throws {
        if holding { held.append((frame, peer)) } else { try await inner.send(frame, to: peer) }
    }

    func hold() { holding = true }

    /// Sends the held frames in the given order (indices into `held`) and stops holding.
    func release(order: [Int]) async throws {
        let frames = held
        held = []
        holding = false
        for index in order { try await inner.send(frames[index].0, to: frames[index].1) }
    }
}

/// A pinned-peer store whose lookups can be held after they read the pin,
/// to reproduce races between a handshake and unpairing.
actor GatedPairedPeerStore: PairedPeerStore {
    private let inner: InMemoryPairedPeerStore
    private var armed = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ peers: [PairedPeer] = []) { inner = InMemoryPairedPeerStore(peers) }

    var suspendedLookups: Int { waiting.count }

    /// Every later `peer(for:)` reads the store, then waits for `releaseLookups()`.
    func armLookupGate() { armed = true }

    func releaseLookups() {
        armed = false
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    func all() async throws -> [PairedPeer] { try await inner.all() }
    func save(_ peer: PairedPeer) async throws { try await inner.save(peer) }
    func remove(_ id: PeerID) async throws { try await inner.remove(id) }

    func peer(for id: PeerID) async throws -> PairedPeer? {
        let snapshot = try await inner.peer(for: id)
        if armed { await withCheckedContinuation { waiting.append($0) } }
        return snapshot
    }
}

/// One device: identity, pinned peers, a Loopback link, and the secure channel.
struct Node {
    let name: String
    let identity: IdentityKeyPair
    let store: GatedPairedPeerStore
    let link: any Transport
    let secure: SecureTransport
    let events: Recorder<TransportEvent>

    var id: PeerID { identity.peerID }

    static func make(
        _ name: String, hub: LoopbackHub, identity: IdentityKeyPair = .generate(),
        pins: [IdentityKeyPair] = [], intercept: Bool = false,
        configuration: SecureTransportConfiguration = SecureTransportConfiguration(handshakeTimeout: .milliseconds(200))
    ) async throws -> Node {
        let store = GatedPairedPeerStore(try pins.map { try PairedPeer(publicKey: $0.publicKey, nickname: "friend", pairedAt: Timestamp(Date())) })
        let loopback = LoopbackTransport(localPeer: identity.peerID, hub: hub)
        let link: any Transport = intercept ? InterceptingLink(loopback) : loopback
        let secure = SecureTransport(wrapping: link, identity: identity, pairedPeers: store, configuration: configuration)
        let events = await Recorder.recording(secure.events)
        return Node(name: name, identity: identity, store: store, link: link, secure: secure, events: events)
    }

    func pin(_ other: IdentityKeyPair) async throws {
        try await store.save(PairedPeer(publicKey: other.publicKey, nickname: "friend", pairedAt: Timestamp(Date())))
    }

    func waitForPeer(_ peer: PeerID) async throws {
        try await eventually("\(name) sees \(peer.short)") { await events.contains(.peerAvailable(peer)) }
    }

    func waitForMessages(_ count: Int) async throws {
        try await eventually("\(name) receives \(count) messages") { await events.received.count >= count }
    }
}

/// Every frame that crossed the hub.
func recordDeliveries(_ hub: LoopbackHub) async -> Recorder<LoopbackHub.Delivery> {
    await Recorder.recording(await hub.deliveries())
}

extension Recorder where Element == LoopbackHub.Delivery {
    func frames(from: PeerID, to: PeerID, type: SecureWire.FrameType) -> [Frame] {
        values.filter { $0.from == from && $0.to == to && $0.frame.bytes.first == type.rawValue }.map(\.frame)
    }
}

/// Lets queued work drain before asserting that something did not happen.
func settle() async throws {
    try await Task.sleep(for: .milliseconds(150))
}
