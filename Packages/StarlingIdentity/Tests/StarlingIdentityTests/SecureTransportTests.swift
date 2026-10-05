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
        // Let the confirm and its acknowledgement land, so tests start quiet.
        try await eventually("both sessions confirmed") {
            let aliceBusy = await alice.secure.status(of: bob.id).handshakeInProgress
            let bobBusy = await bob.secure.status(of: alice.id).handshakeInProgress
            return !aliceBusy && !bobBusy
        }
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
        let secure = SecureTransport(wrapping: link, authority: PinAuthority(identity: aliceKey, store: InMemoryPairedPeerStore()))
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
        // Pairing runs over a live link, so both transports have handled the
        // link coming up before either pins the other. Pinning earlier raced
        // that: a link-up handled after the pin started a second handshake
        // from the other side on a busy event loop, the lone 50 ms attempt
        // expired before its answer, and neither side was left to retry (the
        // higher ID had dropped its own attempt for the lower's). Seen under
        // load 25 to 90; every failure had handshakes in both directions.
        try await eventually("both links are up") {
            let aliceUp = await alice.secure.status(of: bob.id).linkUp
            let bobUp = await bob.secure.status(of: alice.id).linkUp
            return aliceUp && bobUp
        }
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

    /// Review finding HIGH 1, initiator role: a pin lookup that read Bob's
    /// key before he was unpaired must not start a handshake after
    /// `disconnect`, or the removed peer could complete it and be heard.
    @Test func unpairingDuringAnInitiatorPinLookupStopsTheHandshake() async throws {
        let hub = LoopbackHub()
        let wire = await recordDeliveries(hub)
        let (alice, bob) = try await pair(hub: hub)
        await alice.store.armLookupGate()
        let reconnect = Task { await alice.secure.reconnect(bob.id) }
        try await eventually("alice's lookup is suspended") { await alice.store.suspendedLookups == 1 }
        let dials = await wire.frames(from: alice.id, to: bob.id, type: .handshake1).count

        try await alice.store.remove(bob.id)
        await alice.secure.disconnect(bob.id)
        await alice.store.releaseLookups()
        await reconnect.value
        try await settle()

        #expect(await wire.frames(from: alice.id, to: bob.id, type: .handshake1).count == dials)
        #expect(await alice.events.count(.peerAvailable(bob.id)) == 1)
        try? await bob.secure.send(Frame(Data("still friends?".utf8)), to: alice.id)
        try await settle()
        #expect(await alice.events.received.isEmpty)
    }

    /// Review finding HIGH 1, responder role: the same race while answering
    /// Alice's message 1.
    @Test func unpairingDuringAResponderPinLookupStopsTheHandshake() async throws {
        let hub = LoopbackHub()
        let wire = await recordDeliveries(hub)
        let (alice, bob) = try await pair(hub: hub)
        await bob.store.armLookupGate()
        let reconnect = Task { await alice.secure.reconnect(bob.id) }
        try await eventually("bob's lookup is suspended") { await bob.store.suspendedLookups == 1 }
        let answers = await wire.frames(from: bob.id, to: alice.id, type: .handshake2).count

        try await bob.store.remove(alice.id)
        await bob.secure.disconnect(alice.id)
        await bob.store.releaseLookups()
        await reconnect.value
        try await settle()

        #expect(await wire.frames(from: bob.id, to: alice.id, type: .handshake2).count == answers)
        #expect(await bob.events.count(.peerAvailable(alice.id)) == 1)
        try? await alice.secure.send(Frame(Data("still friends?".utf8)), to: bob.id)
        try await settle()
        #expect(await bob.events.received.isEmpty)
    }

    /// Review finding MEDIUM 3, first connection: each side loses its first
    /// transport frame (the initiator's confirm and, once it is sent, the
    /// responder's acknowledgement). Both sides still come up, and traffic
    /// flows both ways without the initiator sending data first.
    @Test(arguments: [false, true]) func aLostConfirmationOnFirstConnectionRecovers(sendFails: Bool) async throws {
        let hub = LoopbackHub()
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey], faulty: true)
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey], faulty: true)
        for node in [alice, bob] {
            let link = try #require(node.link as? FaultyLink)
            if sendFails { await link.fail(nextTransportFrames: 1) } else { await link.drop(nextTransportFrames: 1) }
        }
        try await alice.secure.start()
        try await bob.secure.start()
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)

        let responder = alice.id < bob.id ? bob : alice
        let initiator = alice.id < bob.id ? alice : bob
        try await responder.secure.send(Frame(Data("from responder".utf8)), to: initiator.id)
        try await initiator.waitForMessages(1)
        try await initiator.secure.send(Frame(Data("from initiator".utf8)), to: responder.id)
        try await responder.waitForMessages(1)
    }

    /// Review finding MEDIUM 3, rekey: Alice starts a new session and her
    /// confirm is lost or fails. Bob, still on the old session, keeps
    /// talking; Alice must still hear him, and both converge on the new one.
    @Test(arguments: [false, true]) func aLostConfirmationDuringRekeyLosesNothing(sendFails: Bool) async throws {
        let hub = LoopbackHub()
        let wire = await recordDeliveries(hub)
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey], faulty: true)
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey])
        try await alice.secure.start()
        try await bob.secure.start()
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)

        let link = try #require(alice.link as? FaultyLink)
        if sendFails { await link.fail(nextTransportFrames: 1) } else { await link.drop(nextTransportFrames: 1) }
        let answers = await wire.frames(from: bob.id, to: alice.id, type: .handshake2).count
        await alice.secure.reconnect(bob.id)
        try await eventually("alice's confirm is lost") { await link.dropped + link.failed == 1 }
        #expect(await wire.frames(from: bob.id, to: alice.id, type: .handshake2).count == answers + 1)

        for index in 0..<3 { try await bob.secure.send(Frame(Data("bob \(index)".utf8)), to: alice.id) }
        try await alice.waitForMessages(3)
        // Once the retried confirm lands, both sides use the new session.
        try await eventually("alice's new session is confirmed") { await alice.secure.status(of: bob.id).handshakeInProgress == false }
        try await bob.secure.send(Frame(Data("bob 3".utf8)), to: alice.id)
        try await alice.secure.send(Frame(Data("alice".utf8)), to: bob.id)
        try await alice.waitForMessages(4)
        try await bob.waitForMessages(1)
        #expect(await alice.events.count(.peerAvailable(bob.id)) == 1)
        #expect(await bob.events.count(.peerAvailable(alice.id)) == 1)
    }

    /// Review finding MEDIUM 3, rollover at the message cap: Alice's session
    /// runs out, she starts a new one, and its confirm is lost or fails.
    /// Bob, still on the old session, keeps talking and Alice hears him.
    @Test(arguments: [false, true]) func aLostConfirmationDuringCapRolloverLosesNothing(sendFails: Bool) async throws {
        let hub = LoopbackHub()
        let configuration = SecureTransportConfiguration(maxMessagesPerSession: 4, handshakeTimeout: .milliseconds(200))
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey], faulty: true, configuration: configuration)
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey], configuration: configuration)
        try await alice.secure.start()
        try await bob.secure.start()
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)
        try await settle()

        let link = try #require(alice.link as? FaultyLink)
        if sendFails { await link.fail(nextTransportFrames: 1, controlOnly: true) } else { await link.drop(nextTransportFrames: 1, controlOnly: true) }
        var refused = false
        for index in 0..<8 where !refused {
            do { try await alice.secure.send(Frame(Data("alice \(index)".utf8)), to: bob.id) } catch { refused = true }
        }
        #expect(refused)
        try await eventually("alice's rollover confirm is lost") { await link.dropped + link.failed == 1 }

        for index in 0..<2 { try await bob.secure.send(Frame(Data("bob \(index)".utf8)), to: alice.id) }
        try await alice.waitForMessages(2)
        try await eventually("alice's new session is confirmed") {
            let status = await alice.secure.status(of: bob.id)
            return status.provenKey != nil && !status.handshakeInProgress
        }
        try await alice.secure.send(Frame(Data("after".utf8)), to: bob.id)
        try await eventually("bob hears alice on the new session") { await bob.events.received.contains { $0.0 == Data("after".utf8) } }
    }

    /// Review 2 finding 2: S0 is confirmed; Alice reconnects to S1 and its
    /// confirm is lost; she reconnects to S2 before S1 is confirmed, and that
    /// confirm is lost too. Bob has seen neither, so he still sends under S0,
    /// and Alice must still hear him.
    @Test func twoLostConfirmationsInARowLoseNothing() async throws {
        let hub = LoopbackHub()
        let configuration = SecureTransportConfiguration(handshakeTimeout: .seconds(1))
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey], faulty: true, configuration: configuration)
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey], configuration: configuration)
        try await alice.secure.start()
        try await bob.secure.start()
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)
        try await eventually("S0 confirmed") {
            let aliceBusy = await alice.secure.status(of: bob.id).handshakeInProgress
            let bobBusy = await bob.secure.status(of: alice.id).handshakeInProgress
            return !aliceBusy && !bobBusy
        }

        let link = try #require(alice.link as? FaultyLink)
        await link.drop(nextTransportFrames: 2, controlOnly: true)
        await alice.secure.reconnect(bob.id)
        try await eventually("S1's confirm is lost") { await link.dropped == 1 }
        await alice.secure.reconnect(bob.id)
        try await eventually("S2's confirm is lost") { await link.dropped == 2 }

        for index in 0..<3 { try await bob.secure.send(Frame(Data("bob \(index)".utf8)), to: alice.id) }
        try await alice.waitForMessages(3)
        // The retried S2 confirm then lands and both sides move to S2.
        try await eventually("S2 confirmed") { await !alice.secure.status(of: bob.id).handshakeInProgress }
        try await bob.secure.send(Frame(Data("bob 3".utf8)), to: alice.id)
        try await alice.secure.send(Frame(Data("alice".utf8)), to: bob.id)
        try await alice.waitForMessages(4)
        try await bob.waitForMessages(1)
    }

    /// Review 3 finding 2: from confirmed S0, S1's confirms reach Bob (he
    /// switches to S1) but every acknowledgement is lost; the restarts S2 and
    /// S3 lose their confirms; S3's last timeout spends the budget. Bob is
    /// still sending under S1, and Alice must keep hearing him.
    @Test func aSessionThePeerStillUsesSurvivesTheWholeRestartSequence() async throws {
        let hub = LoopbackHub()
        let wire = await recordDeliveries(hub)
        let configuration = SecureTransportConfiguration(handshakeTimeout: .milliseconds(100), handshakeAttempts: 3)
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey], faulty: true, configuration: configuration)
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey], faulty: true, configuration: configuration)
        try await alice.secure.start()
        try await bob.secure.start()
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)
        try await eventually("S0 confirmed") {
            let aliceBusy = await alice.secure.status(of: bob.id).handshakeInProgress
            let bobBusy = await bob.secure.status(of: alice.id).handshakeInProgress
            return !aliceBusy && !bobBusy
        }

        let aliceLink = try #require(alice.link as? FaultyLink)
        let bobLink = try #require(bob.link as? FaultyLink)
        await bobLink.drop(nextTransportFrames: .max, controlOnly: true)
        // S1's confirm and its 3 retries get through; every later confirm is lost.
        await aliceLink.drop(nextTransportFrames: .max, controlOnly: true, afterPassing: 1 + configuration.handshakeAttempts)
        let dials = await wire.frames(from: alice.id, to: bob.id, type: .handshake1).count
        await alice.secure.reconnect(bob.id)
        try await eventually("alice spends her restart budget") {
            let status = await alice.secure.status(of: bob.id)
            let dialled = await wire.frames(from: alice.id, to: bob.id, type: .handshake1).count - dials
            return dialled == 1 + SecureTransport.maxUnconfirmedRestarts && status.provenKey == nil && !status.handshakeInProgress
        }

        for index in 0..<3 { try await bob.secure.send(Frame(Data("bob \(index)".utf8)), to: alice.id) }
        try await alice.waitForMessages(3)
        // Hearing Bob on S1 confirmed it, so a later failed attempt (S4, its
        // confirms lost too) cannot evict it the way it would evict an
        // unconfirmed session.
        await alice.secure.reconnect(bob.id)
        try await eventually("S4 fails too") {
            let status = await alice.secure.status(of: bob.id)
            let dialled = await wire.frames(from: alice.id, to: bob.id, type: .handshake1).count - dials
            return dialled == 2 + SecureTransport.maxUnconfirmedRestarts && status.provenKey == nil && !status.handshakeInProgress
        }
        try await bob.secure.send(Frame(Data("bob 3".utf8)), to: alice.id)
        try await alice.waitForMessages(4)
    }

    /// Review 4 finding 3: the same sequence as above, but Alice calls
    /// reconnect after the budget is spent and before Bob has sent anything.
    /// With no current session that used to skip the budget, start S4, and
    /// evict S1 when S4 timed out. The attempt must be refused until
    /// authenticated progress or a link reset, and Bob must still be heard.
    @Test func aReconnectCannotEvictASessionThePeerMayStillUse() async throws {
        let hub = LoopbackHub()
        let wire = await recordDeliveries(hub)
        let configuration = SecureTransportConfiguration(handshakeTimeout: .milliseconds(100), handshakeAttempts: 3)
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey], faulty: true, configuration: configuration)
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey], faulty: true, configuration: configuration)
        try await alice.secure.start()
        try await bob.secure.start()
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)
        try await eventually("S0 confirmed") {
            let aliceBusy = await alice.secure.status(of: bob.id).handshakeInProgress
            let bobBusy = await bob.secure.status(of: alice.id).handshakeInProgress
            return !aliceBusy && !bobBusy
        }

        let aliceLink = try #require(alice.link as? FaultyLink)
        let bobLink = try #require(bob.link as? FaultyLink)
        await bobLink.drop(nextTransportFrames: .max, controlOnly: true)
        await aliceLink.drop(nextTransportFrames: .max, controlOnly: true, afterPassing: 1 + configuration.handshakeAttempts)
        let dials = await wire.frames(from: alice.id, to: bob.id, type: .handshake1).count
        await alice.secure.reconnect(bob.id)
        try await eventually("alice spends her restart budget") {
            let status = await alice.secure.status(of: bob.id)
            let dialled = await wire.frames(from: alice.id, to: bob.id, type: .handshake1).count - dials
            return dialled == 1 + SecureTransport.maxUnconfirmedRestarts && status.provenKey == nil && !status.handshakeInProgress
        }

        await alice.secure.reconnect(bob.id)
        // Long enough for a fourth attempt to start and time out completely.
        try await Task.sleep(for: .milliseconds(700))
        #expect(await wire.frames(from: alice.id, to: bob.id, type: .handshake1).count - dials == 1 + SecureTransport.maxUnconfirmedRestarts,
                "no attempt may start while it could evict a session the peer may use")
        for index in 0..<3 { try await bob.secure.send(Frame(Data("bob \(index)".utf8)), to: alice.id) }
        try await alice.waitForMessages(3)
    }

    /// Review 5 finding 3: five reconnects run at once and all wait in the
    /// pin lookup. Released one at a time, each would install a session
    /// (S1 to S5) without rechecking admission: S1's confirm reaches Bob but
    /// his acknowledgement is lost, the later confirms are lost, and
    /// installing S5 would evict S1, which Bob still uses. Admission must be
    /// checked after the lookup, and concurrent reconnects coalesced.
    @Test func concurrentReconnectsCannotEvictASessionThePeerMayStillUse() async throws {
        let hub = LoopbackHub()
        let configuration = SecureTransportConfiguration(handshakeTimeout: .seconds(2), handshakeAttempts: 3)
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey], faulty: true, configuration: configuration)
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey], faulty: true, configuration: configuration)
        try await alice.secure.start()
        try await bob.secure.start()
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)
        try await eventually("S0 confirmed") {
            let aliceBusy = await alice.secure.status(of: bob.id).handshakeInProgress
            let bobBusy = await bob.secure.status(of: alice.id).handshakeInProgress
            return !aliceBusy && !bobBusy
        }

        let aliceLink = try #require(alice.link as? FaultyLink)
        let bobLink = try #require(bob.link as? FaultyLink)
        await bobLink.drop(nextTransportFrames: .max, controlOnly: true)
        await aliceLink.drop(nextTransportFrames: .max, controlOnly: true, afterPassing: 1)
        let aliceBaseline = await aliceLink.matched
        let bobBaseline = await bobLink.matched
        await alice.store.armLookupGate()
        let returned = Counter()
        let attempts = 5
        for _ in 0..<attempts {
            Task {
                await alice.secure.reconnect(bob.id)
                await returned.increment()
            }
        }
        try await eventually("every reconnect is held in its lookup or has returned") {
            let held = await alice.store.suspendedLookups
            let done = await returned.value
            return held + done == attempts
        }

        var installed = 0
        while await alice.store.suspendedLookups > 0 {
            await alice.store.releaseOneLookup()
            installed += 1
            let expected = aliceBaseline + installed
            // The attempt installs its session and sends its first confirm.
            try await eventually("attempt \(installed) sends its confirm") { await aliceLink.matched == expected }
            if installed == 1 {
                // S1's confirm reached Bob, who switched to S1 (his ack is lost).
                try await eventually("bob switches to S1") { await bobLink.matched > bobBaseline }
            }
        }
        await alice.store.releaseLookups()

        for index in 0..<3 { try await bob.secure.send(Frame(Data("bob \(index)".utf8)), to: alice.id) }
        try await alice.waitForMessages(3)
    }

    /// Review 2 finding 3: every confirm (or every acknowledgement) is lost,
    /// so no rolled-over session is ever confirmed, and Alice keeps sending,
    /// so each session soon hits the cap. Replacing an unconfirmed session
    /// must count against the restart budget, so handshakes stop instead of
    /// growing without bound.
    @Test(arguments: [(UInt64(2), false), (2, true), (3, false), (3, true), (4, false), (4, true)])
    func capRolloversOfUnconfirmedSessionsAreBounded(cap: UInt64, loseAcks: Bool) async throws {
        let hub = LoopbackHub()
        let wire = await recordDeliveries(hub)
        let configuration = SecureTransportConfiguration(maxMessagesPerSession: cap, handshakeTimeout: .milliseconds(200), handshakeAttempts: 3)
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey], faulty: true, configuration: configuration)
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey], faulty: true, configuration: configuration)
        try await alice.secure.start()
        try await bob.secure.start()
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)
        try await eventually("S0 confirmed") {
            let aliceBusy = await alice.secure.status(of: bob.id).handshakeInProgress
            let bobBusy = await bob.secure.status(of: alice.id).handshakeInProgress
            return !aliceBusy && !bobBusy
        }

        let lossy = try #require((loseAcks ? bob.link : alice.link) as? FaultyLink)
        await lossy.drop(nextTransportFrames: .max, controlOnly: true)
        let before = await wire.frames(from: alice.id, to: bob.id, type: .handshake1).count
        let sender = Task {
            let clock = SuspendingClock()
            let deadline = clock.now + .milliseconds(1_500)
            var index = 0
            while clock.now < deadline {
                try? await alice.secure.send(Frame(Data("m\(index)".utf8)), to: bob.id)
                index += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        try await Task.sleep(for: .milliseconds(1_000))
        let atOneSecond = await wire.frames(from: alice.id, to: bob.id, type: .handshake1).count - before
        await sender.value
        let atEnd = await wire.frames(from: alice.id, to: bob.id, type: .handshake1).count - before

        // One replacement of the confirmed S0, then at most
        // maxUnconfirmedRestarts replacements of unconfirmed sessions.
        let budget = 1 + SecureTransport.maxUnconfirmedRestarts
        #expect(atOneSecond >= 2, "the cap should force at least one unconfirmed replacement")
        #expect(atOneSecond <= budget, "\(atOneSecond) handshakes after 1 s")
        #expect(atEnd == atOneSecond, "handshakes kept growing: \(atOneSecond) then \(atEnd)")
    }

    @Test func stopFinishesEvents() async throws {
        let (alice, _) = try await pair()
        await alice.secure.stop()
        await #expect(throws: TransportError.stopped) { try await alice.secure.start() }
        await #expect(throws: TransportError.stopped) { try await alice.secure.send(Frame(Data()), to: .random()) }
    }
}
