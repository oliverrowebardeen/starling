import Foundation
import Security
import StarlingCore
import StarlingFakes
@testable import StarlingIdentity
import StarlingTransport
import Synchronization
import Testing

struct TimedOut: Error, CustomStringConvertible {
    let description: String
}

/// Polls `condition` until it holds or `timeout` passes.
///
/// Measured on `SuspendingClock`, which stops while the host sleeps.
/// `ContinuousClock` keeps counting, so a host that slept mid-run woke every
/// waiting test past its deadline at once (seen as a 584 s "timeout" in a
/// test that had run for 0.8 s).
func eventually(
    _ what: String, timeout: Duration = .seconds(5),
    _ condition: @Sendable () async throws -> Bool
) async throws {
    let clock = SuspendingClock()
    let start = clock.now
    let deadline = start + timeout
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TimedOut(description: "timed out waiting for \(what) after \(clock.now - start)")
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

    func append(_ value: Element) { values.append(value) }
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
    private var saveArmed = false
    private var waitingSaves: [CheckedContinuation<Void, Never>] = []

    init(_ peers: [PairedPeer] = []) { inner = InMemoryPairedPeerStore(peers) }

    var suspendedSaves: Int { waitingSaves.count }

    /// Every later `save` waits for `releaseSaves()` before writing.
    func armSaveGate() { saveArmed = true }

    func releaseSaves() {
        saveArmed = false
        for continuation in waitingSaves { continuation.resume() }
        waitingSaves = []
    }

    var suspendedLookups: Int { waiting.count }

    /// Every later `peer(for:)` reads the store, then waits for `releaseLookups()`.
    func armLookupGate() { armed = true }

    func releaseLookups() {
        armed = false
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    /// Lets the oldest held lookup continue; the gate stays armed.
    func releaseOneLookup() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }

    /// Points inside `save` and `remove` where a test can hold the caller.
    enum Point: Hashable, Sendable { case saveBeforeWrite, saveAfterWrite, removeBeforeDelete, removeAfterDelete }
    private var armedPoints: Set<Point> = []
    private var waitingAt: [Point: [CheckedContinuation<Void, Never>]] = [:]

    func arm(_ point: Point) { armedPoints.insert(point) }
    func suspended(at point: Point) -> Int { waitingAt[point]?.count ?? 0 }

    func release(_ point: Point) {
        armedPoints.remove(point)
        for continuation in waitingAt[point] ?? [] { continuation.resume() }
        waitingAt[point] = nil
    }

    private func pause(at point: Point) async {
        guard armedPoints.contains(point) else { return }
        await withCheckedContinuation { waitingAt[point, default: []].append($0) }
    }

    func all() async throws -> [PairedPeer] { try await inner.all() }
    func save(_ peer: PairedPeer) async throws {
        if saveArmed { await withCheckedContinuation { waitingSaves.append($0) } }
        await pause(at: .saveBeforeWrite)
        try await inner.save(peer)
        await pause(at: .saveAfterWrite)
    }
    func remove(_ id: PeerID) async throws {
        await pause(at: .removeBeforeDelete)
        if failRemovals { throw KeychainError(status: errSecIO) }
        try await inner.remove(id)
        await pause(at: .removeAfterDelete)
    }

    /// Makes every later `remove` throw, as a failing Keychain delete would.
    private var failRemovals = false
    func failRemovals(_ fail: Bool) { failRemovals = fail }

    func peer(for id: PeerID) async throws -> PairedPeer? {
        let snapshot = try await inner.peer(for: id)
        if armed { await withCheckedContinuation { waiting.append($0) } }
        return snapshot
    }
}

/// Counts completions from concurrent tasks.
actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// A flag set from synchronous test hooks.
final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    /// Sets the flag; returns whether this call was the one that set it.
    func set() -> Bool { value.withLock { was in defer { was = true }; return !was } }
}

/// A one-shot gate a test can hold async work at.
actor Gate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var waiters: Int { waiting.count }

    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        open = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// A Loopback link whose sends can be held mid-flight, to reproduce races
/// between an outgoing notice and incoming traffic.
actor GatedLink: Transport {
    nonisolated let inner: LoopbackTransport
    nonisolated var kind: TransportKind { inner.kind }
    nonisolated var localPeer: PeerID { inner.localPeer }
    nonisolated var events: AsyncStream<TransportEvent> { inner.events }

    private var armed = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ inner: LoopbackTransport) { self.inner = inner }

    var suspendedSends: Int { waiting.count }

    /// Every later `send` waits for `releaseSends()` before reaching the link.
    func armSendGate() { armed = true }

    func releaseSends() {
        armed = false
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    func start() async throws { try await inner.start() }
    func stop() async { await inner.stop() }

    func send(_ frame: Frame, to peer: PeerID) async throws {
        if armed { await withCheckedContinuation { waiting.append($0) } }
        try await inner.send(frame, to: peer)
    }
}

/// A Loopback link that loses (drops silently) or fails (throws on send)
/// its next few secure-channel transport frames, and passes everything else.
actor FaultyLink: Transport {
    nonisolated let inner: LoopbackTransport
    nonisolated var kind: TransportKind { inner.kind }
    nonisolated var localPeer: PeerID { inner.localPeer }
    nonisolated var events: AsyncStream<TransportEvent> { inner.events }

    private var toDrop = 0
    private var toFail = 0
    private var controlOnly = false
    private var toPass = 0
    private(set) var dropped = 0
    private(set) var failed = 0
    /// Transport frames that matched the fault filter, whatever happened to them.
    private(set) var matched = 0

    init(_ inner: LoopbackTransport) { self.inner = inner }

    /// `controlOnly` limits the fault to confirm and acknowledgement frames,
    /// which carry no payload, so data frames still pass.
    /// `afterPassing` lets that many matching frames through before the fault starts.
    func drop(nextTransportFrames count: Int, controlOnly: Bool = false, afterPassing: Int = 0) {
        (toDrop, self.controlOnly, toPass) = (count, controlOnly, afterPassing)
    }
    func fail(nextTransportFrames count: Int, controlOnly: Bool = false) { (toFail, self.controlOnly) = (count, controlOnly) }

    func start() async throws { try await inner.start() }
    func stop() async { await inner.stop() }

    func send(_ frame: Frame, to peer: PeerID) async throws {
        if frame.bytes.first == SecureWire.FrameType.transport.rawValue,
           !controlOnly || frame.bytes.count == SecureWire.transportOverhead {
            matched += 1
            if toPass > 0 { toPass -= 1; try await inner.send(frame, to: peer); return }
            if toDrop > 0 { toDrop -= 1; dropped += 1; return }
            if toFail > 0 { toFail -= 1; failed += 1; throw TransportError.peerUnreachable(peer) }
        }
        try await inner.send(frame, to: peer)
    }
}

/// One device: identity, pinned peers, a Loopback link, and the secure channel.
struct Node {
    let name: String
    let identity: IdentityKeyPair
    let store: GatedPairedPeerStore
    let authority: PinAuthority
    let link: any Transport
    let secure: SecureTransport
    let events: Recorder<TransportEvent>

    var id: PeerID { identity.peerID }

    static func make(
        _ name: String, hub: LoopbackHub, identity: IdentityKeyPair = .generate(),
        pins: [IdentityKeyPair] = [], intercept: Bool = false, faulty: Bool = false, gated: Bool = false,
        configuration: SecureTransportConfiguration = SecureTransportConfiguration(handshakeTimeout: .milliseconds(200))
    ) async throws -> Node {
        let store = GatedPairedPeerStore(try pins.map { try PairedPeer(publicKey: $0.publicKey, nickname: "friend", pairedAt: Timestamp(Date())) })
        let loopback = LoopbackTransport(localPeer: identity.peerID, hub: hub)
        let link: any Transport = if intercept { InterceptingLink(loopback) } else if faulty { FaultyLink(loopback) } else if gated { GatedLink(loopback) } else { loopback }
        let authority = PinAuthority(identity: identity, store: store)
        let secure = SecureTransport(wrapping: link, authority: authority, configuration: configuration)
        let events = await Recorder.recording(secure.events)
        return Node(name: name, identity: identity, store: store, authority: authority, link: link, secure: secure, events: events)
    }

    /// A second transport for the same device (for example Wi-Fi Aware next
    /// to LocalP2P): same identity, same pinned-peer store, another link.
    static func make(
        _ name: String, hub: LoopbackHub, sharing device: Node,
        configuration: SecureTransportConfiguration = SecureTransportConfiguration(handshakeTimeout: .milliseconds(200))
    ) async throws -> Node {
        let link = LoopbackTransport(localPeer: device.identity.peerID, hub: hub)
        let secure = SecureTransport(wrapping: link, authority: device.authority, configuration: configuration)
        let events = await Recorder.recording(secure.events)
        return Node(name: name, identity: device.identity, store: device.store, authority: device.authority, link: link, secure: secure, events: events)
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
