import Foundation
import StarlingCore
import StarlingFakes
import StarlingTransport
import Testing

@Suite struct LoopbackTests {
    func frame(_ text: String) throws -> Frame { try Frame(Data(text.utf8)) }

    /// Collects events until `count` have arrived.
    func take(_ count: Int, from transport: LoopbackTransport) async -> [TransportEvent] {
        var collected: [TransportEvent] = []
        for await event in transport.events {
            collected.append(event)
            if collected.count == count { break }
        }
        return collected
    }

    @Test func peersDiscoverEachOtherOnStart() async throws {
        let hub = LoopbackHub()
        let a = LoopbackTransport(hub: hub)
        let b = LoopbackTransport(hub: hub)
        try await a.start()
        try await b.start()
        #expect(await take(1, from: a) == [.peerAvailable(b.localPeer)])
        #expect(await take(1, from: b) == [.peerAvailable(a.localPeer)])
    }

    @Test func framesArriveInOrderWithTheSenderAttached() async throws {
        let hub = LoopbackHub()
        let a = LoopbackTransport(hub: hub)
        let b = LoopbackTransport(hub: hub)
        try await a.start()
        try await b.start()
        for index in 0..<100 { try await a.send(frame("\(index)"), to: b.localPeer) }

        let events = await take(101, from: b)
        #expect(events.first == .peerAvailable(a.localPeer))
        #expect(Array(events.dropFirst()) == (0..<100).map { .received(try! frame("\($0)"), from: a.localPeer) })
    }

    @Test func sendingRequiresAStartedTransportAndAKnownPeer() async throws {
        let hub = LoopbackHub()
        let a = LoopbackTransport(hub: hub)
        await #expect(throws: TransportError.notStarted) { try await a.send(frame("x"), to: .random()) }
        try await a.start()
        let stranger = PeerID.random()
        await #expect(throws: TransportError.peerUnreachable(stranger)) { try await a.send(frame("x"), to: stranger) }
        await a.stop()
        await #expect(throws: TransportError.stopped) { try await a.send(frame("x"), to: stranger) }
        await #expect(throws: TransportError.stopped) { try await a.start() }
    }

    @Test func partitionsCutAndHealLinks() async throws {
        let hub = LoopbackHub()
        let a = LoopbackTransport(hub: hub)
        let b = LoopbackTransport(hub: hub)
        try await a.start()
        try await b.start()

        await hub.partition(a.localPeer, b.localPeer)
        await #expect(throws: TransportError.peerUnreachable(b.localPeer)) { try await a.send(frame("x"), to: b.localPeer) }
        await hub.heal(a.localPeer, b.localPeer)
        try await a.send(frame("back"), to: b.localPeer)

        #expect(await take(4, from: b) == [
            .peerAvailable(a.localPeer),
            .peerUnavailable(a.localPeer),
            .peerAvailable(a.localPeer),
            .received(try frame("back"), from: a.localPeer),
        ])
    }

    @Test func stoppingAnnouncesDepartureAndFinishesEvents() async throws {
        let hub = LoopbackHub()
        let a = LoopbackTransport(hub: hub)
        let b = LoopbackTransport(hub: hub)
        try await a.start()
        try await b.start()
        await a.stop()

        #expect(await take(2, from: b) == [.peerAvailable(a.localPeer), .peerUnavailable(a.localPeer)])
        var afterStop: [TransportEvent] = []
        for await event in a.events { afterStop.append(event) }
        #expect(afterStop == [.peerAvailable(b.localPeer)])
        #expect(await hub.peers == [b.localPeer])
    }

    @Test func injectedFramesCarryTheForgedSender() async throws {
        let hub = LoopbackHub()
        let victim = LoopbackTransport(hub: hub)
        try await victim.start()
        let impersonated = PeerID.random()
        try await hub.inject(frame("forged"), claimedSender: impersonated, to: victim.localPeer)
        #expect(await take(1, from: victim) == [.received(try frame("forged"), from: impersonated)])
    }

    @Test func outboxToInboxEndToEnd() async throws {
        let hub = LoopbackHub()
        let alice = LoopbackTransport(hub: hub)
        let bob = LoopbackTransport(hub: hub)
        try await alice.start()
        try await bob.start()
        let bobInbox = Inbox(localPeer: bob.localPeer).events(from: bob)
        let outbox = Outbox(transport: alice, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved))

        let sent = try await outbox.send(
            .reject(Rejection(proposal: MessageID(), reason: .noOverlap)),
            to: bob.localPeer,
            conversation: ConversationID()
        )

        var received: [InboxEvent] = []
        for await event in bobInbox {
            received.append(event)
            if received.count == 2 { break }
        }
        #expect(received == [.peerAvailable(alice.localPeer), .message(sent)])
    }
}
