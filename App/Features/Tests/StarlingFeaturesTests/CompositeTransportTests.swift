import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

@Suite struct CompositeTransportTests {
    let me = PeerID.random()
    let friend = PeerID.random()

    func links() -> (RecordingTransport, RecordingTransport) {
        (RecordingTransport(localPeer: me, kind: .localP2P), RecordingTransport(localPeer: me, kind: .wifiAware))
    }

    func next(_ iterator: inout AsyncStream<TransportEvent>.Iterator) async -> TransportEvent? {
        await iterator.next()
    }

    @Test func aPeerOnTwoLinksIsAnnouncedOnceAndLostOnlyWhenGoneFromBoth() async throws {
        let (local, aware) = links()
        let composite = CompositeTransport(links: [local, aware])
        var events = composite.events.makeAsyncIterator()
        try await composite.start()

        local.inject(.peerAvailable(friend))
        #expect(await next(&events) == .peerAvailable(friend))
        // Each link's events are handled on their own task, so let each one
        // land before the next link reports.
        aware.inject(.peerAvailable(friend))
        try await Task.sleep(for: .milliseconds(20))
        local.inject(.peerUnavailable(friend))
        try await Task.sleep(for: .milliseconds(20))
        aware.inject(.peerUnavailable(friend))
        #expect(await next(&events) == .peerUnavailable(friend), "no second available, and lost only once both links lost it")
    }

    @Test func passesFramesThrough() async throws {
        let (local, aware) = links()
        let composite = CompositeTransport(links: [local, aware])
        var events = composite.events.makeAsyncIterator()
        try await composite.start()
        let frame = try Frame(Data([1, 2, 3]))
        aware.inject(.received(frame, from: friend))
        #expect(await next(&events) == .received(frame, from: friend))
    }

    @Test func sendsOnALinkWhereThePeerIsAvailable() async throws {
        let (local, aware) = links()
        let composite = CompositeTransport(links: [local, aware])
        var events = composite.events.makeAsyncIterator()
        try await composite.start()
        aware.inject(.peerAvailable(friend))
        _ = await next(&events)

        try await composite.send(try Frame(Data([7])), to: friend)
        #expect(await aware.sent.count == 1)
        #expect(await local.sent.isEmpty)
    }

    @Test func failsOverWhenALinkRefuses() async throws {
        let (local, aware) = links()
        let composite = CompositeTransport(links: [local, aware])
        var events = composite.events.makeAsyncIterator()
        try await composite.start()
        local.inject(.peerAvailable(friend))
        _ = await next(&events)
        aware.inject(.peerAvailable(friend))
        await aware.failSends(with: .peerUnreachable(friend))
        try await Task.sleep(for: .milliseconds(20))

        try await composite.send(try Frame(Data([7])), to: friend)
        #expect(await local.sent.count == 1)
    }

    /// Review of PR #51: a cancelled send never fails over to another link.
    @Test func aLinkThatReportsCancellationDoesNotFailOver() async throws {
        let gated = GatedLink(localPeer: me, failure: CancellationError())
        let local = RecordingTransport(localPeer: me, kind: .localP2P)
        let composite = CompositeTransport(links: [local, gated])
        var events = composite.events.makeAsyncIterator()
        try await composite.start()
        local.inject(.peerAvailable(friend))
        _ = await next(&events)
        gated.inject(.peerAvailable(friend))
        try await Task.sleep(for: .milliseconds(20))
        await gated.open()

        await #expect(throws: CancellationError.self) { try await composite.send(try Frame(Data([7])), to: friend) }
        #expect(await local.sent.isEmpty)
    }

    /// A send cancelled while the first link is still trying stops there,
    /// even when that link then fails with an ordinary error.
    @Test func aSendCancelledMidwayDoesNotTryTheNextLink() async throws {
        let gated = GatedLink(localPeer: me, failure: TransportError.peerUnreachable(friend))
        let local = RecordingTransport(localPeer: me, kind: .localP2P)
        let composite = CompositeTransport(links: [local, gated])
        var events = composite.events.makeAsyncIterator()
        try await composite.start()
        local.inject(.peerAvailable(friend))
        _ = await next(&events)
        gated.inject(.peerAvailable(friend))
        try await Task.sleep(for: .milliseconds(20))

        let friend = friend
        let sending = Task { try await composite.send(try Frame(Data([7])), to: friend) }
        await waitUntil { await gated.attempts > 0 }
        sending.cancel()
        await gated.open()
        await #expect(throws: CancellationError.self) { try await sending.value }
        #expect(await local.sent.isEmpty)
    }

    @Test func anUnreachablePeerThrows() async throws {
        let (local, aware) = links()
        let composite = CompositeTransport(links: [local, aware])
        try await composite.start()
        await #expect(throws: TransportError.peerUnreachable(friend)) {
            try await composite.send(try Frame(Data([7])), to: friend)
        }
    }

    @Test func startsAndStopsEveryLink() async throws {
        let (local, aware) = links()
        let composite = CompositeTransport(links: [local, aware])
        try await composite.start()
        #expect(await local.isStarted)
        #expect(await aware.isStarted)
        #expect(composite.localPeer == me)
        await composite.stop()
        #expect(await local.isStarted == false)
        #expect(await aware.isStarted == false)
    }
}

/// A link whose sends wait until the test opens it, then fail with `failure`.
actor GatedLink: Transport {
    nonisolated let kind = TransportKind.wifiAware
    nonisolated let localPeer: PeerID
    nonisolated let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let failure: any Error
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var attempts = 0

    init(localPeer: PeerID, failure: any Error) {
        self.localPeer = localPeer
        self.failure = failure
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    nonisolated func inject(_ event: TransportEvent) { continuation.yield(event) }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func start() async throws {}
    func stop() async { continuation.finish() }

    func send(_ frame: Frame, to peer: PeerID) async throws {
        attempts += 1
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        throw failure
    }
}
