import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

@Suite struct LinkWatcherTests {
    @Test func passesEverythingThroughAndRecordsReachablePeers() async throws {
        let raw = RecordingTransport(kind: .wifiAware)
        let watcher = LinkWatcher(wrapping: raw)
        #expect(watcher.localPeer == raw.localPeer)
        #expect(watcher.kind == .wifiAware)
        var events = watcher.events.makeAsyncIterator()
        try await watcher.start()
        #expect(await raw.isStarted)

        let a = PeerID.random()
        let b = PeerID.random()
        raw.inject(.peerAvailable(a))
        raw.inject(.peerAvailable(b))
        #expect(await events.next() == .peerAvailable(a))
        #expect(await events.next() == .peerAvailable(b))
        #expect(await watcher.reachablePeers() == [a, b])

        raw.inject(.peerUnavailable(a))
        #expect(await events.next() == .peerUnavailable(a))
        #expect(await watcher.reachablePeers() == [b])

        let frame = try Frame(Data([1]))
        raw.inject(.received(frame, from: b))
        #expect(await events.next() == .received(frame, from: b))

        try await watcher.send(frame, to: b)
        #expect(await raw.sent.map(\.peer) == [b])

        await watcher.stop()
        #expect(await raw.isStarted == false)
        #expect(await watcher.reachablePeers().isEmpty)
    }
}
