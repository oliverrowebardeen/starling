import CryptoKit
import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingIdentity
import StarlingTransport
import Testing

@Suite struct SecureTransportTests {
    let aliceKey = IdentityKeyPair.generate()
    let bobKey = IdentityKeyPair.generate()

    func pair(hub: LoopbackHub = LoopbackHub(), interceptAlice: Bool = false,
              configuration: SecureTransportConfiguration = SecureTransportConfiguration(handshakeTimeout: .milliseconds(200)))
    async throws -> (Node, Node) {
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey], intercept: interceptAlice, configuration: configuration)
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey], configuration: configuration)
        try await alice.secure.start()
        try await bob.secure.start()
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)
        return (alice, bob)
    }

    @Test func pairedPeersAuthenticateAndRoundTrip() async throws {
        let (alice, bob) = try await pair()
        try await alice.secure.send(Frame(Data("hello bob".utf8)), to: bob.id)
        try await bob.secure.send(Frame(Data("hello alice".utf8)), to: alice.id)
        try await bob.waitForMessages(1)
        try await alice.waitForMessages(1)
        #expect(await bob.events.received.first?.0 == Data("hello bob".utf8))
        #expect(await bob.events.received.first?.1 == alice.id)
        #expect(await alice.events.received.first?.0 == Data("hello alice".utf8))
        // Exactly one availability event each, under the key-derived ID.
        #expect(await bob.events.count(.peerAvailable(alice.id)) == 1)
        #expect(await alice.events.count(.peerAvailable(bob.id)) == 1)
    }

    @Test func framesAreEncryptedOnTheWire() async throws {
        let hub = LoopbackHub()
        let wire = await recordDeliveries(hub)
        let (alice, bob) = try await pair(hub: hub)
        let secret = Data("the secret plan is boba at 7".utf8)
        try await alice.secure.send(Frame(secret), to: bob.id)
        try await bob.waitForMessages(1)
        let frames = await wire.values.map(\.frame.bytes)
        #expect(!frames.isEmpty)
        #expect(frames.allSatisfy { $0.range(of: secret) == nil })
        #expect(frames.allSatisfy { $0.range(of: Data("boba".utf8)) == nil })
    }

    @Test func unpinnedPeersAreNeverAnnouncedAndTheirFramesDrop() async throws {
        let hub = LoopbackHub()
        let (alice, bob) = try await pair(hub: hub)
        // Carol pins Bob, but Bob never paired with Carol.
        let carol = try await Node.make("carol", hub: hub, pins: [bobKey])
        try await carol.secure.start()
        try await settle()
        #expect(await !bob.events.contains(.peerAvailable(carol.id)))
        #expect(await !carol.events.contains(.peerAvailable(bob.id)))
        await #expect(throws: TransportError.peerUnreachable(bob.id)) {
            try await carol.secure.send(Frame(Data("hi".utf8)), to: bob.id)
        }
        #expect(await bob.events.received.isEmpty)
        #expect(await bob.secure.droppedFrames > 0)
        // Alice and Bob are unaffected.
        try await alice.secure.send(Frame(Data("still here".utf8)), to: bob.id)
        try await bob.waitForMessages(1)
    }

    @Test func tamperedAndTruncatedFramesDrop() async throws {
        let hub = LoopbackHub()
        let wire = await recordDeliveries(hub)
        let (alice, bob) = try await pair(hub: hub)
        try await alice.secure.send(Frame(Data("original".utf8)), to: bob.id)
        try await bob.waitForMessages(1)
        let captured = try #require(await wire.frames(from: alice.id, to: bob.id, type: .transport).last)

        for index in captured.bytes.indices {
            var tampered = captured.bytes
            tampered[index] ^= 0x40
            try await hub.inject(Frame(tampered), claimedSender: alice.id, to: bob.id)
        }
        for length in [0, 1, 9, 10, 25, captured.bytes.count - 1] {
            try await hub.inject(Frame(captured.bytes.prefix(length)), claimedSender: alice.id, to: bob.id)
        }
        try await settle()
        #expect(await bob.events.received.count == 1)

        // The session survives the attack.
        try await alice.secure.send(Frame(Data("after".utf8)), to: bob.id)
        try await bob.waitForMessages(2)
        #expect(await bob.events.received.last?.0 == Data("after".utf8))
    }

    @Test func replayedFramesDrop() async throws {
        let hub = LoopbackHub()
        let wire = await recordDeliveries(hub)
        let (alice, bob) = try await pair(hub: hub)
        try await alice.secure.send(Frame(Data("pay 5".utf8)), to: bob.id)
        try await bob.waitForMessages(1)
        let captured = try #require(await wire.frames(from: alice.id, to: bob.id, type: .transport).last)
        for _ in 0..<3 { try await hub.inject(captured, claimedSender: alice.id, to: bob.id) }
        try await settle()
        #expect(await bob.events.received.count == 1)
    }

    @Test func reorderedFramesDrop() async throws {
        let (alice, bob) = try await pair(interceptAlice: true)
        let link = try #require(alice.link as? InterceptingLink)
        await link.hold()
        try await alice.secure.send(Frame(Data("first".utf8)), to: bob.id)
        try await alice.secure.send(Frame(Data("second".utf8)), to: bob.id)
        #expect(await link.held.count == 2)
        try await link.release(order: [1, 0])
        try await bob.waitForMessages(1)
        try await settle()
        #expect(await bob.events.received.map(\.0) == [Data("second".utf8)])
        // A lost frame does not break the session.
        try await alice.secure.send(Frame(Data("third".utf8)), to: bob.id)
        try await bob.waitForMessages(2)
        #expect(await bob.events.received.map(\.0) == [Data("second".utf8), Data("third".utf8)])
    }

    /// Concurrent senders still produce strictly increasing nonces on the link.
    @Test func concurrentSendsArriveWithoutLoss() async throws {
        let (alice, bob) = try await pair()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask { try await alice.secure.send(Frame(Data("\(index)".utf8)), to: bob.id) }
            }
            try await group.waitForAll()
        }
        try await bob.waitForMessages(50)
        #expect(Set(await bob.events.received.map(\.0)).count == 50)
    }

    @Test func frameSizeLimits() async throws {
        let hub = LoopbackHub()
        let wire = await recordDeliveries(hub)
        let (alice, bob) = try await pair(hub: hub)
        let largest = Data(repeating: 7, count: ProtocolLimits.maxEnvelopeBytes)
        try await alice.secure.send(Frame(largest), to: bob.id)
        try await bob.waitForMessages(1)
        #expect(await bob.events.received.first?.0 == largest)
        let ciphertext = try #require(await wire.frames(from: alice.id, to: bob.id, type: .transport).last)
        #expect(ciphertext.bytes.count == ProtocolLimits.maxEnvelopeBytes + SecureWire.transportOverhead)
        #expect(ciphertext.bytes.count <= ProtocolLimits.maxFrameBytes)

        await #expect(throws: TransportError.self) {
            try await alice.secure.send(Frame(Data(count: ProtocolLimits.maxEnvelopeBytes + 1)), to: bob.id)
        }
    }

    /// ADR 0003 care requirement 3: a session ends before its nonce can wrap,
    /// and a new handshake takes over.
    @Test func sessionsRollOverBeforeTheNonceCap() async throws {
        let hub = LoopbackHub()
        let wire = await recordDeliveries(hub)
        let configuration = SecureTransportConfiguration(maxMessagesPerSession: 4, handshakeTimeout: .milliseconds(200))
        let (alice, bob) = try await pair(hub: hub, configuration: configuration)

        var delivered = 0
        var refused = 0
        for index in 0..<12 {
            do {
                try await alice.secure.send(Frame(Data("m\(index)".utf8)), to: bob.id)
                delivered += 1
            } catch TransportError.peerUnreachable {
                refused += 1
                let expected = refused + 1
                try await eventually("alice re-handshakes") { await alice.events.count(.peerAvailable(bob.id)) >= expected }
            }
        }
        #expect(refused >= 2)
        try await bob.waitForMessages(delivered)
        // No transport frame ever carried a nonce at or above the cap.
        let nonces = await wire.frames(from: alice.id, to: bob.id, type: .transport)
            .compactMap { SecureWire.parseTransport(Data($0.bytes.dropFirst()))?.0 }
        #expect(nonces.allSatisfy { $0 < 4 })
        #expect(await wire.frames(from: alice.id, to: bob.id, type: .handshake1).count
            + wire.frames(from: bob.id, to: alice.id, type: .handshake1).count >= 3)
    }

    @Test func wrappedTransportMustUseTheIdentityPeerID() async throws {
        let hub = LoopbackHub()
        let link = LoopbackTransport(localPeer: .random(), hub: hub)
        let secure = SecureTransport(wrapping: link, identity: aliceKey, pairedPeers: InMemoryPairedPeerStore())
        await #expect(throws: TransportError.self) { try await secure.start() }
    }

    /// Pairing finished on Alice first; Bob pins her a moment later. Her
    /// handshake retry connects them without either side reconnecting.
    @Test func handshakeRetriesWhenTheResponderPinsLate() async throws {
        let hub = LoopbackHub()
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey])
        let bob = try await Node.make("bob", hub: hub, identity: bobKey)
        try await alice.secure.start()
        try await bob.secure.start()
        try await settle()
        #expect(await !alice.events.contains(.peerAvailable(bob.id)))
        try await bob.pin(aliceKey)
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)
    }

    @Test func reconnectAfterPairing() async throws {
        let hub = LoopbackHub()
        let configuration = SecureTransportConfiguration(handshakeTimeout: .milliseconds(50), handshakeAttempts: 1)
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, configuration: configuration)
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, configuration: configuration)
        try await alice.secure.start()
        try await bob.secure.start()
        try await alice.pin(bobKey)
        try await bob.pin(aliceKey)
        await bob.secure.reconnect(alice.id)
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)
    }

    @Test func simultaneousHandshakesConverge() async throws {
        let (alice, bob) = try await pair()
        for _ in 0..<5 {
            async let a: Void = alice.secure.reconnect(bob.id)
            async let b: Void = bob.secure.reconnect(alice.id)
            _ = await (a, b)
        }
        try await settle()
        try await alice.secure.send(Frame(Data("ping".utf8)), to: bob.id)
        try await bob.secure.send(Frame(Data("pong".utf8)), to: alice.id)
        try await bob.waitForMessages(1)
        try await alice.waitForMessages(1)
    }

    /// A replayed handshake message 1 gets no answer and does not disturb the session.
    @Test func replayedHandshakeIsIgnored() async throws {
        let hub = LoopbackHub()
        let wire = await recordDeliveries(hub)
        let (alice, bob) = try await pair(hub: hub)
        let initiator = alice.id < bob.id ? alice : bob
        let responder = alice.id < bob.id ? bob : alice
        let hello = try #require(await wire.frames(from: initiator.id, to: responder.id, type: .handshake1).first)
        let replies = await wire.frames(from: responder.id, to: initiator.id, type: .handshake2).count
        try await hub.inject(hello, claimedSender: initiator.id, to: responder.id)
        try await settle()
        #expect(await wire.frames(from: responder.id, to: initiator.id, type: .handshake2).count == replies)
        try await initiator.secure.send(Frame(Data("ok".utf8)), to: responder.id)
        try await responder.waitForMessages(1)
    }

    @Test func replayedHandshakeIsIgnoredAfterALinkFlap() async throws {
        let hub = LoopbackHub()
        let wire = await recordDeliveries(hub)
        let (alice, bob) = try await pair(hub: hub)
        let initiator = alice.id < bob.id ? alice : bob
        let responder = alice.id < bob.id ? bob : alice
        let hello = try #require(await wire.frames(from: initiator.id, to: responder.id, type: .handshake1).first)
        await hub.partition(alice.id, bob.id)
        await hub.heal(alice.id, bob.id)
        try await eventually("reconnected") { await responder.events.count(.peerAvailable(initiator.id)) == 2 }
        let replies = await wire.frames(from: responder.id, to: initiator.id, type: .handshake2).count
        try await hub.inject(hello, claimedSender: initiator.id, to: responder.id)
        try await settle()
        #expect(await wire.frames(from: responder.id, to: initiator.id, type: .handshake2).count == replies)
    }

    @Test func linkLossIsReportedAndRecovered() async throws {
        let hub = LoopbackHub()
        let (alice, bob) = try await pair(hub: hub)
        await hub.partition(alice.id, bob.id)
        try await eventually("alice sees bob leave") { await alice.events.contains(.peerUnavailable(bob.id)) }
        await #expect(throws: TransportError.peerUnreachable(bob.id)) { try await alice.secure.send(Frame(Data()), to: bob.id) }
        await hub.heal(alice.id, bob.id)
        try await eventually("reconnected") { await alice.events.count(.peerAvailable(bob.id)) == 2 }
        try await alice.secure.send(Frame(Data("back".utf8)), to: bob.id)
        try await bob.waitForMessages(1)
    }

    @Test func disconnectEndsTheSession() async throws {
        let (alice, bob) = try await pair()
        try await bob.store.remove(alice.id)
        await bob.secure.disconnect(alice.id)
        try await eventually("bob reports alice gone") { await bob.events.contains(.peerUnavailable(alice.id)) }
        await #expect(throws: TransportError.peerUnreachable(alice.id)) { try await bob.secure.send(Frame(Data()), to: alice.id) }
        // Alice's old session keys no longer reach Bob's app.
        try? await alice.secure.send(Frame(Data("hello?".utf8)), to: bob.id)
        try await settle()
        #expect(await bob.events.received.isEmpty)
    }

    @Test func stopFinishesEvents() async throws {
        let (alice, _) = try await pair()
        await alice.secure.stop()
        await #expect(throws: TransportError.stopped) { try await alice.secure.start() }
        await #expect(throws: TransportError.stopped) { try await alice.secure.send(Frame(Data()), to: .random()) }
    }
}
