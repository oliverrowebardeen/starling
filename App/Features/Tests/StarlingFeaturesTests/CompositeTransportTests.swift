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
