import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingIdentity
import StarlingTransport
import Testing

/// Revocation notices reach observers in their own tasks (issue #32), so a
/// notice can arrive after newer work has begun. Each notice carries the
/// epoch its revocation produced; an observer may clean up only what was
/// authenticated or started under an older epoch. These tests deliver a
/// revocation's notice late, deterministically, by calling the observer
/// with that epoch after the newer work began.
@Suite struct RevocationNoticeTests {
    let aliceKey = IdentityKeyPair.generate()
    let bobKey = IdentityKeyPair.generate()

    func connected(gateBob: Bool = false) async throws -> (Node, Node) {
        let hub = LoopbackHub()
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey])
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey], gated: gateBob)
        try await alice.secure.start()
        try await bob.secure.start()
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)
        return (alice, bob)
    }

    /// Disconnects Bob at Alice and returns the epoch that produced.
    func disconnectBob(_ alice: Node, _ bob: Node) async -> UInt64 {
        await alice.secure.disconnect(bob.id)
        return alice.authority.epoch(of: bob.id)
    }

    @Test func aLateNoticeLeavesAReconnectsLookupAlone() async throws {
        let (alice, bob) = try await connected()
        let epoch = await disconnectBob(alice, bob)
        await alice.store.armLookupGate()
        let reconnect = Task { await alice.secure.reconnect(bob.id) }
        try await eventually("the reconnect's lookup began") { await alice.store.suspendedLookups == 1 }

        await alice.secure.revocationNotice(bob.id, epoch: epoch)
        await alice.store.releaseLookups()
        await reconnect.value

        try await eventually("alice reconnects to bob") { await alice.events.count(.peerAvailable(bob.id)) == 2 }
        try await bob.secure.send(Frame(Data("hello again".utf8)), to: alice.id)
        try await alice.waitForMessages(1)
    }

    @Test func aLateNoticeLeavesAnInstalledHandshakeAlone() async throws {
        let (alice, bob) = try await connected(gateBob: true)
        let epoch = await disconnectBob(alice, bob)
        let bobLink = try #require(bob.link as? GatedLink)
        await bobLink.armSendGate()
        await alice.secure.reconnect(bob.id)
        // Alice's message 1 is out; Bob's reply is held.
        try await eventually("bob's reply is held") { await bobLink.suspendedSends >= 1 }
        #expect(await alice.secure.status(of: bob.id).handshakeInProgress)

        await alice.secure.revocationNotice(bob.id, epoch: epoch)
        #expect(await alice.secure.status(of: bob.id).handshakeInProgress, "the newer handshake must survive")
        await bobLink.releaseSends()

        try await eventually("alice reconnects to bob") { await alice.events.count(.peerAvailable(bob.id)) == 2 }
    }

    @Test func aLateNoticeLeavesANewerSessionAlone() async throws {
        let (alice, bob) = try await connected()
        let epoch = await disconnectBob(alice, bob)
        await alice.secure.reconnect(bob.id)
        try await eventually("alice reconnects to bob") { await alice.events.count(.peerAvailable(bob.id)) == 2 }

        await alice.secure.revocationNotice(bob.id, epoch: epoch)
        #expect(await alice.secure.status(of: bob.id).provenKey == bobKey.publicKey)
        #expect(await alice.events.count(.peerUnavailable(bob.id)) == 1)
        try await bob.secure.send(Frame(Data("still here".utf8)), to: alice.id)
        try await alice.waitForMessages(1)
    }

    @Test func aLateNoticeLeavesACeremonyStartedAfterTheRevocationAlone() async throws {
        let (alice, bob) = try await connected()
        let alicePairing = PairingService(secureTransport: alice.secure, configuration: .fast)
        let bobPairing = PairingService(secureTransport: bob.secure, configuration: .fast)
        try await alicePairing.start()
        try await bobPairing.start()
        let epoch = await disconnectBob(alice, bob)

        let sa = try await alicePairing.pair(with: bob.id, nickname: "Bob")
        let sb = try await bobPairing.pair(with: alice.id, nickname: "Alice")
        let ea = await Recorder.recording(sa.events)
        let eb = await Recorder.recording(sb.events)
        _ = try await ea.waitForCode()
        _ = try await eb.waitForCode()

        await alicePairing.revocationNotice(bob.id, epoch: epoch)
        await sa.confirm(codesMatch: true)
        await sb.confirm(codesMatch: true)
        guard case .paired = try await ea.waitForOutcome() else {
            Issue.record("a ceremony started after the revocation must not be cancelled by its late notice")
            return
        }
        withExtendedLifetime([alicePairing, bobPairing]) {}
    }

    /// The control: a ceremony that started before the revocation is still
    /// cancelled by its notice.
    @Test func aNoticeCancelsACeremonyStartedBeforeTheRevocation() async throws {
        let (alice, bob) = try await connected()
        let alicePairing = PairingService(secureTransport: alice.secure, configuration: .fast)
        let bobPairing = PairingService(secureTransport: bob.secure, configuration: .fast)
        try await alicePairing.start()
        try await bobPairing.start()
        let sa = try await alicePairing.pair(with: bob.id, nickname: "Bob")
        _ = try await bobPairing.pair(with: alice.id, nickname: "Alice")
        let ea = await Recorder.recording(sa.events)
        _ = try await ea.waitForCode()

        let epoch = await disconnectBob(alice, bob)
        await alicePairing.revocationNotice(bob.id, epoch: epoch)
        #expect(try await ea.waitForOutcome() == .failed(.cancelled))
        withExtendedLifetime([alicePairing, bobPairing]) {}
    }
}
