import Foundation
import StarlingCore
@testable import StarlingWiFiAware
import Testing

/// Short timings so link races, grace periods, and backoff run in milliseconds.
private let fastTiming = AwareTiming(
    helloTimeout: .seconds(2),
    fallbackDelay: .milliseconds(150),
    retryDelay: { attempt in attempt <= 5 ? .milliseconds(20 * attempt) : nil },
    radioRestartDelay: { _ in .milliseconds(20) }
)

/// Collects a transport's events, which have a single consumer.
private actor EventLog {
    private(set) var events: [TransportEvent] = []
    private(set) var finished = false

    func append(_ event: TransportEvent) { events.append(event) }
    func finish() { finished = true }

    func count(_ event: TransportEvent) -> Int { events.filter { $0 == event }.count }

    func received(from peer: PeerID) -> [Data] {
        events.compactMap { event in
            if case let .received(frame, from) = event, from == peer { return frame.bytes }
            return nil
        }
    }
}

private struct Phone {
    let name: String
    let peer: PeerID
    let transport: WiFiAwareTransport
    let log: EventLog

    init(_ name: String, air: FakeAir, peer: PeerID = .random(), timing: AwareTiming = fastTiming) async {
        self.name = name
        self.peer = peer
        transport = WiFiAwareTransport(localPeer: peer, radio: await air.radio(for: name), timing: timing)
        let log = EventLog()
        self.log = log
        let events = transport.events
        Task {
            for await event in events { await log.append(event) }
            await log.finish()
        }
    }

    func available(_ other: Phone) async -> Int { await log.count(.peerAvailable(other.peer)) }
    func unavailable(_ other: Phone) async -> Int { await log.count(.peerUnavailable(other.peer)) }
    func frames(from other: Phone) async -> [Data] { await log.received(from: other.peer) }
}

/// Polls until `condition` holds, failing the test after `timeout`.
private func eventually(
    _ what: String,
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
}

/// Two peers ordered so `high > low`.
private func orderedPeers() -> (high: PeerID, low: PeerID) {
    let x = PeerID.random()
    let y = PeerID.random()
    return x > y ? (x, y) : (y, x)
}

private func frame(_ index: Int) throws -> Frame {
    try Frame(Data("frame-\(index)".utf8))
}

@Suite struct WiFiAwareTransportTests {
    @Test func pairedPhonesLinkOnceAndExchangeFramesInOrder() async throws {
        let air = FakeAir()
        await air.pair("a", "b")
        let a = await Phone("a", air: air)
        let b = await Phone("b", air: air)
        try await a.transport.start()
        try await b.transport.start()

        await eventually("both linked") {
            let first = await a.available(b) == 1
            let second = await b.available(a) == 1
            return first && second
        }
        for index in 0..<10 {
            try await a.transport.send(try frame(index), to: b.peer)
            try await b.transport.send(try frame(index + 100), to: a.peer)
        }
        await eventually("frames arrive") {
            let first = await b.frames(from: a).count == 10
            let second = await a.frames(from: b).count == 10
            return first && second
        }
        #expect(await b.frames(from: a) == (0..<10).map { Data("frame-\($0)".utf8) })
        #expect(await a.frames(from: b) == (100..<110).map { Data("frame-\($0)".utf8) })

        // The dial race settled on one link, not two.
        await eventually("duplicate closed") { await air.openConnectionCount("a", "b") == 1 }
        #expect(await a.unavailable(b) == 0)
        #expect(await b.unavailable(a) == 0)

        await a.transport.stop()
        await b.transport.stop()
    }

    /// Both phones dial on first contact. Frames sent the moment a peer is
    /// available must all arrive, which is what dial-both-and-arbitrate got
    /// wrong in ADR 0004's first LocalP2P design.
    @Test(arguments: 0..<15)
    func firstContactDialRaceLosesNoFrames(run: Int) async throws {
        let air = FakeAir()
        await air.pair("a", "b")
        let a = await Phone("a", air: air)
        let b = await Phone("b", air: air)
        async let startA: Void = a.transport.start()
        async let startB: Void = b.transport.start()
        _ = try await (startA, startB)

        await eventually("a sees b") { await a.available(b) == 1 }
        for index in 0..<20 { try await a.transport.send(try frame(index), to: b.peer) }
        await eventually("all frames arrive") { await b.frames(from: a).count == 20 }
        // Both sides really did dial: this was a race, not a one-sided dial.
        #expect(await air.dialCount["a", default: 0] == 1)
        #expect(await air.dialCount["b", default: 0] == 1)
        #expect(await b.frames(from: a) == (0..<20).map { Data("frame-\($0)".utf8) })
        #expect(await a.unavailable(b) == 0)
        #expect(await b.unavailable(a) == 0)

        await a.transport.stop()
        await b.transport.stop()
    }

    /// A's browser never sees B, so only B dials, and B has the lower
    /// PeerID: its outgoing link is the one `LinkArbiter` does not prefer. The
    /// link must still become usable, after the grace period.
    @Test func oneSidedDiscoveryLinksAfterTheGracePeriod() async throws {
        let air = FakeAir()
        await air.pair("a", "b")
        await air.setHidden("b", from: "a", true)
        let (high, low) = orderedPeers()
        let a = await Phone("a", air: air, peer: high)
        let b = await Phone("b", air: air, peer: low)
        let started = ContinuousClock.now
        try await a.transport.start()
        try await b.transport.start()

        await eventually("both linked") {
            let first = await a.available(b) == 1
            let second = await b.available(a) == 1
            return first && second
        }
        #expect(ContinuousClock.now - started >= fastTiming.fallbackDelay)
        try await a.transport.send(try frame(1), to: b.peer)
        try await b.transport.send(try frame(2), to: a.peer)
        await eventually("frames arrive") {
            let first = await b.frames(from: a).count == 1
            let second = await a.frames(from: b).count == 1
            return first && second
        }
        #expect(await air.dialCount["a", default: 0] == 0)

        await a.transport.stop()
        await b.transport.stop()
    }

    /// Grace timers on the two phones do not expire together. A frame on a
    /// provisional link proves the sender treats it as active, so the
    /// receiver activates it at once instead of dropping the frame.
    @Test func aFrameOnAProvisionalLinkActivatesItForTheReceiver() async throws {
        let air = FakeAir()
        await air.pair("a", "b")
        await air.setHidden("b", from: "a", true)
        let (high, low) = orderedPeers()
        var slowGrace = fastTiming
        slowGrace.fallbackDelay = .seconds(30)
        let a = await Phone("a", air: air, peer: high)
        let b = await Phone("b", air: air, peer: low, timing: slowGrace)
        try await a.transport.start()
        try await b.transport.start()

        await eventually("a activates after its grace period") { await a.available(b) == 1 }
        #expect(await b.available(a) == 0)
        try await a.transport.send(try frame(5), to: b.peer)
        await eventually("b activates on the frame", timeout: .seconds(2)) {
            let first = await b.available(a) == 1
            let second = await b.frames(from: a) == [Data("frame-5".utf8)]
            return first && second
        }
        // The availability event comes before the frame it was triggered by.
        #expect(await b.log.events.first == .peerAvailable(a.peer))

        await a.transport.stop()
        await b.transport.stop()
    }

    @Test func reconnectsAfterWalkingOutOfRangeAndBack() async throws {
        let air = FakeAir()
        await air.pair("a", "b")
        let a = await Phone("a", air: air)
        let b = await Phone("b", air: air)
        try await a.transport.start()
        try await b.transport.start()
        await eventually("linked") {
            let first = await a.available(b) == 1
            let second = await b.available(a) == 1
            return first && second
        }

        await air.setInRange("a", "b", false)
        await eventually("both notice") {
            let first = await a.unavailable(b) == 1
            let second = await b.unavailable(a) == 1
            return first && second
        }
        await #expect(throws: TransportError.peerUnreachable(b.peer)) { try await a.transport.send(try frame(0), to: b.peer) }

        let dialsBefore = (await air.dialCount["a", default: 0], await air.dialCount["b", default: 0])
        await air.setInRange("a", "b", true)
        await eventually("relinked") {
            let first = await a.available(b) == 2
            let second = await b.available(a) == 2
            return first && second
        }
        try await b.transport.send(try frame(7), to: a.peer)
        await eventually("frame arrives") { await a.frames(from: b) == [Data("frame-7".utf8)] }

        // Each side now knows the other's PeerID, so only the preferred side
        // dialed; the other waited and found the link already up.
        try await Task.sleep(for: fastTiming.fallbackDelay * 2)
        let dialsA = await air.dialCount["a", default: 0] - dialsBefore.0
        let dialsB = await air.dialCount["b", default: 0] - dialsBefore.1
        #expect(dialsA + dialsB == 1)
        #expect((dialsA == 1) == (a.peer > b.peer))

        await a.transport.stop()
        await b.transport.stop()
    }

    @Test func redialsALinkThatDropsWhileBothStayDiscovered() async throws {
        let air = FakeAir()
        await air.pair("a", "b")
        let a = await Phone("a", air: air)
        let b = await Phone("b", air: air)
        try await a.transport.start()
        try await b.transport.start()
        await eventually("linked") {
            let first = await a.available(b) == 1
            let second = await b.available(a) == 1
            return first && second
        }

        await air.dropConnections("a", "b")
        await eventually("relinked") {
            let first = await a.available(b) == 2
            let second = await b.available(a) == 2
            return first && second
        }
        #expect(await a.unavailable(b) == 1)
        try await a.transport.send(try frame(3), to: b.peer)
        await eventually("frame arrives") { await b.frames(from: a) == [Data("frame-3".utf8)] }

        await a.transport.stop()
        await b.transport.stop()
    }

    @Test func redialBackoffIsBoundedAndResetsOnRediscovery() async throws {
        let air = FakeAir()
        await air.pair("a", "b")
        await air.setDialsFail("a", true)
        await air.setDialsFail("b", true)
        let a = await Phone("a", air: air)
        let b = await Phone("b", air: air)
        try await a.transport.start()
        try await b.transport.start()

        // One dial on discovery plus five retries, then nothing more.
        await eventually("attempts exhausted") { await air.dialCount["a", default: 0] == 6 }
        try await Task.sleep(for: .milliseconds(500))
        #expect(await air.dialCount["a", default: 0] == 6)
        #expect(await air.dialCount["b", default: 0] == 6)

        await air.setDialsFail("a", false)
        await air.setDialsFail("b", false)
        await air.setInRange("a", "b", false)
        await air.setInRange("a", "b", true)
        await eventually("linked after rediscovery") {
            let first = await a.available(b) == 1
            let second = await b.available(a) == 1
            return first && second
        }

        await a.transport.stop()
        await b.transport.stop()
    }

    /// Browser updates carry the whole discovered set. An update about some
    /// other device must not hand an exhausted device a fresh dial, or the
    /// backoff is unbounded in any busy room.
    @Test func updatesAboutOtherDevicesDoNotRedialAnExhaustedDevice() async throws {
        let air = FakeAir()
        await air.pair("a", "b")
        await air.pair("a", "c")
        await air.setDialsFail("a", true)
        await air.setDialsFail("b", true)
        let a = await Phone("a", air: air)
        let b = await Phone("b", air: air)
        let c = await Phone("c", air: air)
        try await a.transport.start()
        try await b.transport.start()

        // One dial on discovery plus five retries, then the budget is spent.
        await eventually("a exhausts its budget for b") { await air.dials(from: "a", to: "b") == 6 }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await air.dials(from: "a", to: "b") == 6)

        // C appears, then flickers: three browser updates on A, all still listing B.
        try await c.transport.start()
        await eventually("c links to a") { await c.available(a) == 1 }
        await air.setHidden("c", from: "a", true)
        await air.setHidden("c", from: "a", false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await air.dials(from: "a", to: "b") == 6)

        for phone in [a, b, c] { await phone.transport.stop() }
    }

    // MARK: Picked device to PeerID

    private func device(_ target: String, seenBy phone: String, in air: FakeAir) async throws -> WiFiAwarePairedDevice {
        let id = try #require(await air.deviceID(of: target, seenBy: phone))
        return WiFiAwarePairedDevice(id: id, name: target)
    }

    @Test func mapsAPickedDeviceToItsPeerOnceTheHelloArrives() async throws {
        let air = FakeAir()
        await air.pair("a", "b")
        let a = await Phone("a", air: air)
        let b = await Phone("b", air: air)
        let bOnA = try await device("b", seenBy: "a", in: air)
        #expect(await a.transport.peerID(for: bOnA) == nil)

        try await a.transport.start()
        try await b.transport.start()
        await eventually("linked") { await a.available(b) == 1 }
        #expect(await a.transport.peerID(for: bOnA) == b.peer)
        #expect(await b.transport.peerID(for: try await device("a", seenBy: "b", in: air)) == a.peer)

        // Still known after the link drops, so a pairing can start right away.
        await air.setInRange("a", "b", false)
        await eventually("dropped") { await a.unavailable(b) == 1 }
        #expect(await a.transport.peerID(for: bOnA) == b.peer)

        await a.transport.stop()
        await b.transport.stop()
    }

    @Test func waitsForTheHelloOfAPickedDevice() async throws {
        let air = FakeAir()
        await air.pair("a", "b")
        let a = await Phone("a", air: air)
        let b = await Phone("b", air: air)
        let bOnA = try await device("b", seenBy: "a", in: air)
        try await a.transport.start()

        let transport = a.transport
        let lookup = Task { await transport.peerID(for: bOnA, waitingUpTo: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        try await b.transport.start()
        #expect(await lookup.value == b.peer)

        await a.transport.stop()
        await b.transport.stop()
    }

    @Test func waitingForAPickedDeviceEndsWithNilOnTimeoutStopOrCancel() async throws {
        let air = FakeAir()
        await air.pair("a", "b")
        let a = await Phone("a", air: air)
        let bOnA = try await device("b", seenBy: "a", in: air)
        try await a.transport.start()
        let transport = a.transport

        let started = ContinuousClock.now
        #expect(await transport.peerID(for: bOnA, waitingUpTo: .milliseconds(100)) == nil)
        #expect(ContinuousClock.now - started >= .milliseconds(100))

        let cancelled = Task { await transport.peerID(for: bOnA, waitingUpTo: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        #expect(await cancelled.value == nil)

        let stopped = Task { await transport.peerID(for: bOnA, waitingUpTo: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(50))
        await transport.stop()
        #expect(await stopped.value == nil)
        #expect(await transport.peerID(for: bOnA, waitingUpTo: .seconds(30)) == nil)
    }

    @Test func keepsOneLinkPerPairedDevice() async throws {
        let air = FakeAir()
        let names = ["a", "b", "c", "d"]
        for (i, x) in names.enumerated() { for y in names[(i + 1)...] { await air.pair(x, y) } }
        var phones: [Phone] = []
        for name in names { phones.append(await Phone(name, air: air)) }
        for phone in phones { try await phone.transport.start() }

        for phone in phones {
            for other in phones where other.name != phone.name {
                await eventually("\(phone.name) sees \(other.name)") { await phone.available(other) == 1 }
            }
        }
        for (i, x) in names.enumerated() {
            for y in names[(i + 1)...] {
                await eventually("one link \(x)-\(y)") { await air.openConnectionCount(x, y) == 1 }
            }
        }
        // Check every table before stopping anyone: a stopped phone's links
        // drop on the others, correctly.
        for phone in phones {
            #expect(await phone.transport.linkTable.links.count == 3)
        }
        for phone in phones { await phone.transport.stop() }
    }

    @Test func stopAnnouncesUnavailabilityFinishesEventsAndCancelsWork() async throws {
        let air = FakeAir()
        await air.pair("a", "b")
        let a = await Phone("a", air: air)
        let b = await Phone("b", air: air)
        try await a.transport.start()
        try await b.transport.start()
        await eventually("linked") {
            let first = await a.available(b) == 1
            let second = await b.available(a) == 1
            return first && second
        }

        await a.transport.stop()
        await eventually("a's events finish") { await a.log.finished }
        #expect(await a.unavailable(b) == 1)
        #expect(await a.transport.pendingTaskCount == 0)
        await eventually("b notices") { await b.unavailable(a) == 1 }
        await #expect(throws: TransportError.stopped) { try await a.transport.send(try frame(0), to: b.peer) }
        await #expect(throws: TransportError.stopped) { try await a.transport.start() }

        await b.transport.stop()
    }

    @Test func sendingBeforeStartOrToAnUnknownPeerThrows() async throws {
        let air = FakeAir()
        let a = await Phone("a", air: air)
        let stranger = PeerID.random()
        await #expect(throws: TransportError.notStarted) { try await a.transport.send(try frame(0), to: stranger) }
        try await a.transport.start()
        await #expect(throws: TransportError.peerUnreachable(stranger)) { try await a.transport.send(try frame(0), to: stranger) }
        await a.transport.stop()
    }

    @Test func startReportsARadioThatCannotRun() async throws {
        struct Broken: AwareRadio {
            func preflight() throws { throw FakeRadioError(reason: "service not declared") }
            func browse(_ update: @escaping @Sendable (Set<AwareDeviceID>) async -> Void) async throws {}
            func listen(_ accept: @escaping @Sendable (any AwareChannel) async -> Void) async throws {}
            func dial(_ device: AwareDeviceID, _ body: @escaping @Sendable (any AwareChannel) async -> Void) async throws {}
        }
        let transport = WiFiAwareTransport(localPeer: .random(), radio: Broken(), timing: fastTiming)
        await #expect(throws: TransportError.self) { try await transport.start() }
    }

    /// A hostile or confused device that claims our own PeerID gets no link.
    @Test func ignoresAPeerClaimingOurOwnID() async throws {
        let air = FakeAir()
        await air.pair("a", "b")
        let shared = PeerID.random()
        let a = await Phone("a", air: air, peer: shared)
        let b = await Phone("b", air: air, peer: shared)
        try await a.transport.start()
        try await b.transport.start()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await a.log.events.isEmpty)
        #expect(await b.log.events.isEmpty)
        await a.transport.stop()
        await b.transport.stop()
    }
}
