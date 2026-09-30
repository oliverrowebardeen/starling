import CryptoKit
import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingIdentity
import StarlingTransport
import Testing

/// Mallory knows Alice's and Bob's public keys (they are not secret) and
/// controls the link: she can forge the envelope sender, forge the link's
/// sender ID, and even take over Alice's link address. None of it reaches
/// Bob's `Inbox`. This is the simulator's `impersonation` scenario
/// (Tools/Simulator/Scenarios) with the secure channel in place.
@Suite struct ImpersonationTests {
    let aliceKey = IdentityKeyPair.generate()
    let bobKey = IdentityKeyPair.generate()
    let malloryKey = IdentityKeyPair.generate()

    func forgedEnvelope(from sender: PeerID, to recipient: PeerID) throws -> Envelope {
        try Envelope(
            conversation: ConversationID(), sender: sender, recipient: recipient,
            sequence: 0, sentAt: Timestamp(Date()),
            body: .reject(Rejection(proposal: MessageID(), reason: .declinedByOwner))
        )
    }

    /// Runs Bob's recorded secure-channel events through a real `Inbox`.
    func inboxMessages(_ bob: Node) async -> [Envelope] {
        let inbox = Inbox(localPeer: bob.id)
        var messages: [Envelope] = []
        for event in await bob.events.values {
            if case .message(let envelope) = await inbox.process(event) { messages.append(envelope) }
        }
        return messages
    }

    @Test func forgedSenderAndForgedLinkIdentityAreRejected() async throws {
        let hub = LoopbackHub()
        let wire = await recordDeliveries(hub)
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey])
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey])
        try await alice.secure.start()
        try await bob.secure.start()
        try await bob.waitForPeer(alice.id)

        let codec = EnvelopeCodec()
        let forged = try codec.encode(forgedEnvelope(from: alice.id, to: bob.id))

        // 1. The Phase 0 attack: a plaintext envelope claiming Alice, on a link claiming Alice.
        try await hub.inject(Frame(forged), claimedSender: alice.id, to: bob.id)
        // 2. The same bytes dressed up as a secure-channel transport frame.
        try await hub.inject(SecureWire.frame(.transport, Data(count: 8) + forged), claimedSender: alice.id, to: bob.id)
        // 3. A KK handshake claiming to be Alice, run with Mallory's own key.
        var handshake = try NoiseHandshakeState(
            pattern: .kk, initiator: true, prologue: SecureWire.kkPrologue,
            localStatic: malloryKey.privateKey, remoteStatic: bobKey.privateKey.publicKey
        )
        let answersBefore = await wire.frames(from: bob.id, to: alice.id, type: .handshake2).count
        try await hub.inject(SecureWire.frame(.handshake1, handshake.writeMessage(payload: Data())), claimedSender: alice.id, to: bob.id)
        try await settle()

        #expect(await wire.frames(from: bob.id, to: alice.id, type: .handshake2).count == answersBefore, "Bob must not answer Mallory")
        #expect(await bob.events.received.isEmpty)
        #expect(await inboxMessages(bob).isEmpty)

        // Alice's real message still gets through, attributed to her.
        let genuine = try forgedEnvelope(from: alice.id, to: bob.id)
        try await alice.secure.send(Frame(codec.encode(genuine)), to: bob.id)
        try await bob.waitForMessages(1)
        #expect(await inboxMessages(bob).map(\.id) == [genuine.id])
    }

    /// Mallory takes over Alice's address on the link itself (the hub routes
    /// Alice's ID to her). She still cannot complete a handshake as Alice, and
    /// what Bob sends to that address is ciphertext she cannot read.
    @Test func hijackedLinkAddressGainsNothing() async throws {
        let hub = LoopbackHub()
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey])
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey])
        try await alice.secure.start()
        try await bob.secure.start()
        try await bob.waitForPeer(alice.id)

        let hijack = LoopbackTransport(localPeer: alice.id, hub: hub)
        let stolen = await Recorder.recording(hijack.events)
        try await hijack.start()

        let secret = Data("meet at 7".utf8)
        try? await bob.secure.send(Frame(secret), to: alice.id)
        var handshake = try NoiseHandshakeState(
            pattern: .kk, initiator: true, prologue: SecureWire.kkPrologue,
            localStatic: malloryKey.privateKey, remoteStatic: bobKey.privateKey.publicKey
        )
        try await hijack.send(SecureWire.frame(.handshake1, handshake.writeMessage(payload: Data())), to: bob.id)
        try await hijack.send(Frame(EnvelopeCodec().encode(forgedEnvelope(from: alice.id, to: bob.id))), to: bob.id)
        try await settle()

        #expect(await stolen.received.allSatisfy { $0.0.range(of: secret) == nil })
        #expect(await !stolen.received.contains { $0.0.first == SecureWire.FrameType.handshake2.rawValue })
        #expect(await inboxMessages(bob).isEmpty)
    }

    /// Lane E2's link table keys links by the PeerID a link hello claims, so
    /// an OS-paired device can claim Alice's ID and displace her link without
    /// Bob seeing a disconnect. Bob's authenticated session is not replaced
    /// or shadowed: the impostor's handshakes and frames drop, and Bob's
    /// status still shows the key Alice proved.
    @Test func aDisplacingLinkDoesNotShadowTheAuthenticatedSession() async throws {
        let hub = LoopbackHub()
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey])
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey])
        try await alice.secure.start()
        try await bob.secure.start()
        try await bob.waitForPeer(alice.id)

        let impostor = LoopbackTransport(localPeer: alice.id, hub: hub)
        try await impostor.start()
        for _ in 0..<3 {
            var handshake = try NoiseHandshakeState(
                pattern: .kk, initiator: true, prologue: SecureWire.kkPrologue,
                localStatic: malloryKey.privateKey, remoteStatic: bobKey.privateKey.publicKey
            )
            try await impostor.send(SecureWire.frame(.handshake1, handshake.writeMessage(payload: Data())), to: bob.id)
            try await impostor.send(SecureWire.transportFrame(nonce: 1_000, ciphertext: Data(count: 40)), to: bob.id)
        }
        try await settle()

        let status = await bob.secure.status(of: alice.id)
        #expect(status.provenKey == aliceKey.publicKey)
        #expect(status.provenKey?.peerID == status.claimedPeer)
        #expect(status.droppedFrames >= 6)
        #expect(await bob.events.count(.peerAvailable(alice.id)) == 1)
        #expect(await !bob.events.contains(.peerUnavailable(alice.id)))
        #expect(await bob.events.received.isEmpty)
    }

    /// The other displacement shape: the link reports Alice gone, then an
    /// impostor's link appears under her ID. Bob drops the dead session (the
    /// link says it cannot reach her), and the impostor never gets a new one.
    @Test func anImpostorLinkAfterLinkLossIsNeverAnnounced() async throws {
        let hub = LoopbackHub()
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey])
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey])
        try await alice.secure.start()
        try await bob.secure.start()
        try await bob.waitForPeer(alice.id)

        await hub.partition(alice.id, bob.id)
        try await eventually("bob sees alice leave") { await bob.events.contains(.peerUnavailable(alice.id)) }
        let impostor = LoopbackTransport(localPeer: alice.id, hub: hub)
        let impostorInbound = await Recorder.recording(impostor.events)
        try await impostor.start()
        await hub.heal(alice.id, bob.id)
        // Bob dials "Alice"; the impostor receives message 1 and cannot answer it.
        try await eventually("bob dials the claimed ID") {
            await impostorInbound.received.contains { $0.0.first == SecureWire.FrameType.handshake1.rawValue }
        }
        var handshake = try NoiseHandshakeState(
            pattern: .kk, initiator: true, prologue: SecureWire.kkPrologue,
            localStatic: malloryKey.privateKey, remoteStatic: bobKey.privateKey.publicKey
        )
        try await impostor.send(SecureWire.frame(.handshake1, handshake.writeMessage(payload: Data())), to: bob.id)
        try await impostor.send(SecureWire.frame(.handshake2, Data(count: SecureWire.handshakeLength)), to: bob.id)
        try await settle()

        let status = await bob.secure.status(of: alice.id)
        #expect(status.linkUp)
        #expect(status.provenKey == nil)
        #expect(status.droppedFrames >= 2)
        #expect(await bob.events.count(.peerAvailable(alice.id)) == 1)
        await #expect(throws: TransportError.peerUnreachable(alice.id)) { try await bob.secure.send(Frame(Data("x".utf8)), to: alice.id) }
    }

    /// Key-compromise impersonation: Mallory has stolen Bob's private key and
    /// uses it to forge KK message 1 "from Alice" (KK message 1 alone cannot
    /// resist this; Noise rev 34 section 7.7 rates its sender authentication 1).
    /// Bob answers, but the session only goes live after a frame from the
    /// initiator decrypts, which needs Alice's key, so Bob never announces her.
    @Test func aStolenResponderKeyCannotImpersonateTheInitiator() async throws {
        let hub = LoopbackHub()
        let wire = await recordDeliveries(hub)
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey])
        try await bob.secure.start()
        let hijack = LoopbackTransport(localPeer: aliceKey.peerID, hub: hub)
        try await hijack.start()

        let (aliceKey, bobKey) = (aliceKey, bobKey)
        @Sendable func forgedMessage1() throws -> Data {
            var symmetric = NoiseSymmetricState(protocolName: Data(NoisePattern.kk.protocolName.utf8))
            symmetric.mixHash(SecureWire.kkPrologue)
            symmetric.mixHash(aliceKey.publicKey.bytes)
            symmetric.mixHash(bobKey.publicKey.bytes)
            let ephemeral = X25519PrivateKey()
            symmetric.mixHash(ephemeral.publicKey.rawRepresentation)
            symmetric.mixKey(try NoiseHandshakeState.dh(ephemeral, bobKey.privateKey.publicKey))
            // ss, computed from Bob's side with his stolen key.
            symmetric.mixKey(try NoiseHandshakeState.dh(bobKey.privateKey, aliceKey.privateKey.publicKey))
            return ephemeral.publicKey.rawRepresentation + (try symmetric.encryptAndHash(Data()))
        }
        // Bob also dials "Alice" when her address appears. If his PeerID is the
        // lower one he ignores message 1 while his own attempt is in flight, so
        // keep sending fresh forgeries until his attempts lapse.
        try await eventually("bob answers a forged message 1") {
            try await hijack.send(SecureWire.frame(.handshake1, forgedMessage1()), to: bob.id)
            try await Task.sleep(for: .milliseconds(50))
            return await !wire.frames(from: bob.id, to: aliceKey.peerID, type: .handshake2).isEmpty
        }
        // Mallory cannot derive the transport keys (se needs Alice's key), so
        // anything she sends next fails to decrypt.
        for nonce in UInt64(0)..<8 {
            try await hijack.send(SecureWire.transportFrame(nonce: nonce, ciphertext: Data((0..<40).map { _ in UInt8.random(in: 0...255) })), to: bob.id)
        }
        try await settle()
        #expect(await !bob.events.contains(.peerAvailable(aliceKey.peerID)))
        #expect(await bob.events.received.isEmpty)
    }

    /// A paired friend who turns malicious is authenticated as herself, so an
    /// envelope claiming to be from Alice is caught by `Inbox`'s sender check.
    @Test func aPairedPeerCannotSpeakForAnother() async throws {
        let hub = LoopbackHub()
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey, malloryKey])
        let mallory = try await Node.make("mallory", hub: hub, identity: malloryKey, pins: [bobKey])
        try await bob.secure.start()
        try await mallory.secure.start()
        try await bob.waitForPeer(mallory.id)

        try await mallory.secure.send(Frame(EnvelopeCodec().encode(forgedEnvelope(from: aliceKey.peerID, to: bob.id))), to: bob.id)
        try await bob.waitForMessages(1)
        #expect(await bob.events.received.first?.1 == mallory.id)
        let inbox = Inbox(localPeer: bob.id)
        let (bytes, from) = try #require(await bob.events.received.first)
        let frame = try Frame(bytes)
        #expect(await inbox.process(.received(frame, from: from)) == .dropped(from: mallory.id, reason: .senderMismatch))
    }
}
