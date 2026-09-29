import Foundation
import StarlingCore
import StarlingLocalP2P
import Testing

/// Two real transports in one process, over Bonjour on this Mac. Opt in with
/// STARLING_NETWORK_TESTS=1: CI runners and sandboxes may block multicast DNS,
/// and macOS may ask for Local Network permission the first time.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STARLING_NETWORK_TESTS"] == "1"))
struct LocalP2PIntegrationTests {
    @Test(.timeLimit(.minutes(1)))
    func twoTransportsDiscoverEachOtherAndExchangeFrames() async throws {
        let a = LocalP2PTransport(localPeer: .random(), includePeerToPeer: false)
        let b = LocalP2PTransport(localPeer: .random(), includePeerToPeer: false)
        try await a.start()
        try await b.start()
        defer { Task { await a.stop(); await b.stop() } }

        try await waitForPeer(b.localPeer, on: a)
        let payloads = (0..<20).map { Data("frame \($0)".utf8) }
        for payload in payloads { try await a.send(Frame(payload), to: b.localPeer) }

        var received: [Data] = []
        for await event in b.events {
            if case .received(let frame, let sender) = event {
                #expect(sender == a.localPeer)
                received.append(frame.bytes)
                if received.count == payloads.count { break }
            }
        }
        #expect(received == payloads)
    }

    /// Both sides dial each other, so each has two connections until the
    /// arbiter drops one. Traffic must still flow both ways, and each side
    /// must report the other as available exactly once.
    @Test(.timeLimit(.minutes(1)))
    func duplicateConnectionsResolveAndTrafficFlowsBothWays() async throws {
        let a = LocalP2PTransport(localPeer: .random(), includePeerToPeer: false)
        let b = LocalP2PTransport(localPeer: .random(), includePeerToPeer: false)
        try await a.start()
        try await b.start()
        defer { Task { await a.stop(); await b.stop() } }

        try await waitForPeer(b.localPeer, on: a)
        // Give the second connection time to arrive and be arbitrated.
        try await Task.sleep(for: .seconds(2))
        try await a.send(Frame(Data("to b".utf8)), to: b.localPeer)
        try await b.send(Frame(Data("to a".utf8)), to: a.localPeer)

        var availableOnB = 0
        for await event in b.events {
            if event == .peerAvailable(a.localPeer) { availableOnB += 1 }
            if event == .received(try Frame(Data("to b".utf8)), from: a.localPeer) { break }
            if event == .peerUnavailable(a.localPeer) { Issue.record("link dropped during arbitration") }
        }
        #expect(availableOnB == 1)
        for await event in a.events {
            if event == .received(try Frame(Data("to a".utf8)), from: b.localPeer) { break }
            if event == .peerUnavailable(b.localPeer) { Issue.record("link dropped during arbitration") }
        }
    }

    private func waitForPeer(_ peer: PeerID, on transport: LocalP2PTransport) async throws {
        for await event in transport.events {
            if event == .peerAvailable(peer) { return }
        }
        throw TransportError.peerUnreachable(peer)
    }
}
