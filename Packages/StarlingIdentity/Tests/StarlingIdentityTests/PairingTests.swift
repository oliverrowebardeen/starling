import CryptoKit
import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingIdentity
import StarlingTransport
import Synchronization
import Testing

/// One phone in a pairing test: identity, store, raw link, and the service.
struct PairingDevice {
    let identity: IdentityKeyPair
    let store: InMemoryPairedPeerStore
    let link: GatedLink
    let service: PairingService

    var id: PeerID { identity.peerID }

    static func make(hub: LoopbackHub, identity: IdentityKeyPair = .generate(), configuration: PairingConfiguration = .fast) async throws -> PairingDevice {
        let store = InMemoryPairedPeerStore()
        let link = GatedLink(LoopbackTransport(localPeer: identity.peerID, hub: hub))
        let service = PairingService(authority: PinAuthority(identity: identity, store: store), link: link, configuration: configuration)
        try await service.start()
        return PairingDevice(identity: identity, store: store, link: link, service: service)
    }
}

extension PairingConfiguration {
    static let fast = PairingConfiguration(handshakeTimeout: .seconds(2), confirmationTimeout: .seconds(2))
}

extension Recorder where Element == PairingEvent {
    var code: String? {
        values.lazy.compactMap { if case .confirmCode(let code) = $0 { code } else { nil } }.first
    }

    var outcome: PairingEvent? {
        values.last.flatMap { if case .confirmCode = $0 { nil } else { $0 } }
    }

    func waitForCode() async throws -> String {
        try await eventually("a code") { await code != nil }
        return try #require(code)
    }

    func waitForOutcome() async throws -> PairingEvent {
        try await eventually("an outcome") { await outcome != nil }
        return try #require(outcome)
    }
}

@Suite struct PairingTests {
    func start(_ a: PairingDevice, _ b: PairingDevice) async throws -> (Recorder<PairingEvent>, Recorder<PairingEvent>, any PairingSession, any PairingSession) {
        let sa = try await a.service.pair(with: b.id, nickname: "Bob")
        let sb = try await b.service.pair(with: a.id, nickname: "Alice")
        return (await Recorder.recording(sa.events), await Recorder.recording(sb.events), sa, sb)
    }

    @Test func bothOwnersConfirmAndBothSidesPinTheOther() async throws {
        let hub = LoopbackHub()
        let alice = try await PairingDevice.make(hub: hub)
        let bob = try await PairingDevice.make(hub: hub)
        let (ea, eb, sa, sb) = try await start(alice, bob)

        let codeA = try await ea.waitForCode()
        let codeB = try await eb.waitForCode()
        #expect(codeA == codeB)
        #expect(codeA.count == 6 && codeA.allSatisfy(\.isNumber))

        await sa.confirm(codesMatch: true)
        try await settle()
        #expect(try await alice.store.all().isEmpty, "nothing is stored until both owners confirm")
        await sb.confirm(codesMatch: true)

        guard case .paired(let bobAsSeenByAlice) = try await ea.waitForOutcome(),
              case .paired(let aliceAsSeenByBob) = try await eb.waitForOutcome()
        else { Issue.record("expected both sides to pair"); return }
        #expect(bobAsSeenByAlice.publicKey == bob.identity.publicKey)
        #expect(bobAsSeenByAlice.nickname == "Bob")
        #expect(aliceAsSeenByBob.publicKey == alice.identity.publicKey)
        #expect(try await alice.store.all() == [bobAsSeenByAlice])
        #expect(try await bob.store.all() == [aliceAsSeenByBob])
    }

    @Test func aMismatchLeavesNothingStoredOnEitherSide() async throws {
        let hub = LoopbackHub()
        let alice = try await PairingDevice.make(hub: hub)
        let bob = try await PairingDevice.make(hub: hub)
        let (ea, eb, sa, sb) = try await start(alice, bob)
        _ = try await ea.waitForCode()
        _ = try await eb.waitForCode()
        await sb.confirm(codesMatch: true)
        await sa.confirm(codesMatch: false)
        #expect(try await ea.waitForOutcome() == .failed(.codeMismatch))
        #expect(try await eb.waitForOutcome() == .failed(.codeMismatch))
        #expect(try await alice.store.all().isEmpty)
        #expect(try await bob.store.all().isEmpty)
    }

    @Test func aCancelLeavesNothingStoredOnEitherSide() async throws {
        let hub = LoopbackHub()
        let alice = try await PairingDevice.make(hub: hub)
        let bob = try await PairingDevice.make(hub: hub)
        let (ea, eb, sa, sb) = try await start(alice, bob)
        _ = try await eb.waitForCode()
        await sa.confirm(codesMatch: true)
        await sb.cancel()
        #expect(try await ea.waitForOutcome() == .failed(.cancelled))
        #expect(try await eb.waitForOutcome() == .failed(.cancelled))
        #expect(try await alice.store.all().isEmpty)
        #expect(try await bob.store.all().isEmpty)
    }

    /// Review finding HIGH 2: Alice confirms, then cancels. While her cancel
    /// notice is still being sent, Bob confirms and his accept arrives. Her
    /// cancel is final: she must not pin Bob. (Bob, who saw both accepts,
    /// does pin Alice: the one-sided outcome ADR 0101 documents.)
    @Test func anAcceptArrivingDuringACancelDoesNotPin() async throws {
        let hub = LoopbackHub()
        let alice = try await PairingDevice.make(hub: hub)
        let bob = try await PairingDevice.make(hub: hub)
        let (ea, eb, sa, sb) = try await start(alice, bob)
        _ = try await ea.waitForCode()
        _ = try await eb.waitForCode()
        await sa.confirm(codesMatch: true)

        await alice.link.armSendGate()
        let cancelling = Task { await sa.cancel() }
        try await eventually("alice's cancel notice is in flight") { await alice.link.suspendedSends == 1 }
        await sb.confirm(codesMatch: true)
        try await settle()

        #expect(try await ea.waitForOutcome() == .failed(.cancelled))
        #expect(try await alice.store.all().isEmpty)
        await alice.link.releaseSends()
        await cancelling.value
        #expect(try await alice.store.all().isEmpty)
    }

    /// Review finding HIGH 2, timeout path: Alice confirmed, her answer timer
    /// fires, and Bob's accept arrives while her notice is still being sent.
    @Test func anAcceptArrivingDuringATimeoutDoesNotPin() async throws {
        let hub = LoopbackHub()
        let alice = try await PairingDevice.make(hub: hub, configuration: PairingConfiguration(handshakeTimeout: .seconds(2), confirmationTimeout: .milliseconds(300)))
        let bob = try await PairingDevice.make(hub: hub)
        let (ea, eb, sa, sb) = try await start(alice, bob)
        _ = try await ea.waitForCode()
        _ = try await eb.waitForCode()
        await sa.confirm(codesMatch: true)
        try await settle()

        await alice.link.armSendGate()
        try await eventually("alice's timeout notice is in flight") { await alice.link.suspendedSends == 1 }
        await sb.confirm(codesMatch: true)
        try await settle()

        #expect(try await ea.waitForOutcome() == .failed(.timedOut))
        #expect(try await alice.store.all().isEmpty)
        await alice.link.releaseSends()
    }

    @Test func anUnansweredCodeTimesOutWithNothingStored() async throws {
        let hub = LoopbackHub()
        let fast = PairingConfiguration(handshakeTimeout: .seconds(2), confirmationTimeout: .milliseconds(200))
        let alice = try await PairingDevice.make(hub: hub, configuration: fast)
        let bob = try await PairingDevice.make(hub: hub)
        let (ea, eb, sa, _) = try await start(alice, bob)
        _ = try await ea.waitForCode()
        await sa.confirm(codesMatch: true)
        // Alice gives up first and tells Bob, whose phone ends the ceremony too.
        #expect(try await ea.waitForOutcome() == .failed(.timedOut))
        #expect(try await eb.waitForOutcome() == .failed(.cancelled))
        #expect(try await alice.store.all().isEmpty)
        #expect(try await bob.store.all().isEmpty)
    }

    @Test func aOneSidedCeremonyTimesOut() async throws {
        let hub = LoopbackHub()
        let fast = PairingConfiguration(handshakeTimeout: .milliseconds(200), confirmationTimeout: .seconds(2))
        let alice = try await PairingDevice.make(hub: hub, configuration: fast)
        let bob = try await PairingDevice.make(hub: hub, configuration: fast)
        let session = try await alice.service.pair(with: bob.id, nickname: "Bob")
        let events = await Recorder.recording(session.events)
        #expect(try await events.waitForOutcome() == .failed(.timedOut))
        #expect(await events.code == nil)
    }

    /// Either owner may tap Pair first.
    @Test func eitherSideMayStartFirst() async throws {
        for delayResponder in [true, false] {
            let hub = LoopbackHub()
            let alice = try await PairingDevice.make(hub: hub)
            let bob = try await PairingDevice.make(hub: hub)
            let (early, late) = (alice.id < bob.id) == delayResponder ? (alice, bob) : (bob, alice)
            let first = try await early.service.pair(with: late.id, nickname: "Later")
            let firstEvents = await Recorder.recording(first.events)
            try await Task.sleep(for: .milliseconds(100))
            let second = try await late.service.pair(with: early.id, nickname: "Earlier")
            let secondEvents = await Recorder.recording(second.events)
            #expect(try await firstEvents.waitForCode() == secondEvents.waitForCode())
        }
    }

    @Test func linkLossFailsTheCeremony() async throws {
        let hub = LoopbackHub()
        let alice = try await PairingDevice.make(hub: hub)
        let bob = try await PairingDevice.make(hub: hub)
        let (ea, _, _, _) = try await start(alice, bob)
        _ = try await ea.waitForCode()
        await hub.partition(alice.id, bob.id)
        #expect(try await ea.waitForOutcome() == .failed(.transportFailed))
        #expect(try await alice.store.all().isEmpty)
    }

    /// Garbage and forged frames claiming to be the peer do not derail or end
    /// the ceremony: they fail to parse or decrypt and are dropped.
    @Test func injectedTrafficIsIgnored() async throws {
        let hub = LoopbackHub()
        let alice = try await PairingDevice.make(hub: hub)
        let bob = try await PairingDevice.make(hub: hub)
        let (ea, eb, sa, sb) = try await start(alice, bob)
        _ = try await ea.waitForCode()
        _ = try await eb.waitForCode()
        let types: [PairingCeremony.MessageType] = [.hello, .message1, .message2, .message3, .secure]
        for type in types {
            for length in [0, 1, 32, 48, 80, 200] {
                let junk = Data([type.rawValue]) + Data((0..<length).map { _ in UInt8.random(in: 0...255) })
                try await hub.inject(Frame(junk), claimedSender: bob.id, to: alice.id)
                try await hub.inject(Frame(junk), claimedSender: alice.id, to: bob.id)
            }
        }
        // An unauthenticated abort after keys exist is ignored too.
        try await hub.inject(Frame(Data([PairingCeremony.MessageType.abort.rawValue])), claimedSender: bob.id, to: alice.id)
        await sa.confirm(codesMatch: true)
        await sb.confirm(codesMatch: true)
        guard case .paired = try await ea.waitForOutcome(), case .paired = try await eb.waitForOutcome() else {
            Issue.record("expected pairing to survive injected traffic"); return
        }
    }

    /// Mallory sits between Alice and Bob with her own keys, running one
    /// ceremony with each (Alice thinks Mallory's device is Bob's). The two
    /// codes differ, so the owners see different numbers and reject.
    @Test func aManInTheMiddleShowsDifferentCodes() async throws {
        let left = LoopbackHub()
        let right = LoopbackHub()
        let alice = try await PairingDevice.make(hub: left)
        let malloryLeft = try await PairingDevice.make(hub: left)
        let malloryRight = try await PairingDevice.make(hub: right)
        let bob = try await PairingDevice.make(hub: right)

        let (ea, _, sa, _) = try await start(alice, malloryLeft)
        let (_, eb, _, sb) = try await start(malloryRight, bob)
        let codeAlice = try await ea.waitForCode()
        let codeBob = try await eb.waitForCode()
        // Fails spuriously with probability 10^-6, the bound the code is designed for.
        #expect(codeAlice != codeBob)

        await sa.confirm(codesMatch: false)
        await sb.confirm(codesMatch: false)
        #expect(try await ea.waitForOutcome() == .failed(.codeMismatch))
        #expect(try await eb.waitForOutcome() == .failed(.codeMismatch))
        #expect(try await alice.store.all().isEmpty)
        #expect(try await bob.store.all().isEmpty)
    }

    /// A responder that reveals a different nonce from the one it committed
    /// to (the move that would let it steer the code) is rejected.
    @Test func aResponderThatBreaksItsCommitmentIsRejected() async throws {
        let hub = LoopbackHub()
        var victimKey = IdentityKeyPair.generate()
        var attackerKey = IdentityKeyPair.generate()
        if attackerKey.peerID < victimKey.peerID { swap(&victimKey, &attackerKey) }
        let victim = try await PairingDevice.make(hub: hub, identity: victimKey)
        let attackerLink = LoopbackTransport(localPeer: attackerKey.peerID, hub: hub)
        let inbound = await Recorder.recording(attackerLink.events)
        try await attackerLink.start()

        let session = try await victim.service.pair(with: attackerKey.peerID, nickname: "Bob")
        let events = await Recorder.recording(session.events)
        typealias T = PairingCeremony.MessageType
        func next(_ type: T) async throws -> Data {
            try await eventually("\(type)") { await inbound.received.contains { $0.0.first == type.rawValue } }
            let frames = await inbound.received.filter { $0.0.first == type.rawValue }
            return Data(try #require(frames.last).0.dropFirst())
        }

        try await attackerLink.send(Frame(Data([T.hello.rawValue])), to: victim.id)
        var handshake = try NoiseHandshakeState(
            pattern: .xx, initiator: false, prologue: PairingCeremony.prologue,
            localStatic: attackerKey.privateKey, remoteStatic: nil
        )
        _ = try handshake.readMessage(await next(.message1))
        let committed = PairingCode.nonce()
        try await attackerLink.send(Frame(Data([T.message2.rawValue]) + handshake.writeMessage(payload: PairingCode.commitment(to: committed))), to: victim.id)
        _ = try handshake.readMessage(await next(.message3))
        var noise = try handshake.session()
        let swapped = PairingCode.nonce()
        let reveal = try noise.send.encrypt(ad: Data(), plaintext: Data([PairingCeremony.SecureKind.reveal.rawValue]) + swapped)
        try await attackerLink.send(Frame(Data([T.secure.rawValue]) + reveal), to: victim.id)

        #expect(try await events.waitForOutcome() == .failed(.protocolError))
        #expect(await events.code == nil, "no code is ever shown")
        #expect(try await victim.store.all().isEmpty)
    }

    @Test func invalidRequestsThrow() async throws {
        let hub = LoopbackHub()
        let identity = IdentityKeyPair.generate()
        let service = PairingService(authority: PinAuthority(identity: identity, store: InMemoryPairedPeerStore()), link: LoopbackTransport(localPeer: identity.peerID, hub: hub))
        await #expect(throws: PairingServiceError.notStarted) { try await service.pair(with: .random(), nickname: "Bob") }
        try await service.start()
        await #expect(throws: PairingServiceError.cannotPairWithSelf) { try await service.pair(with: identity.peerID, nickname: "Me") }
        await #expect(throws: ValidationError.self) { try await service.pair(with: .random(), nickname: " ") }
    }

    @Test func codesAreSixDigitsAndBindEveryInput() {
        let h = Data(repeating: 1, count: 32), ni = Data(repeating: 2, count: 32), nr = Data(repeating: 3, count: 32)
        let code = PairingCode.code(handshakeHash: h, initiatorNonce: ni, responderNonce: nr)
        #expect(code.count == 6 && code.allSatisfy(\.isNumber))
        #expect(code == PairingCode.code(handshakeHash: h, initiatorNonce: ni, responderNonce: nr))
        #expect(code != PairingCode.code(handshakeHash: ni, initiatorNonce: ni, responderNonce: nr))
        #expect(code != PairingCode.code(handshakeHash: h, initiatorNonce: nr, responderNonce: nr))
        #expect(code != PairingCode.code(handshakeHash: h, initiatorNonce: ni, responderNonce: ni))
        #expect(PairingCode.commitment(to: ni) != PairingCode.commitment(to: nr))
    }
}

/// Pairing and the secure channel share one link: pair through
/// `SecureTransport.pairingLink`, then talk over the authenticated channel.
@Suite struct PairThenTalkTests {
    @Test func pairingThenSecureChannel() async throws {
        let hub = LoopbackHub()
        let alice = try await Node.make("alice", hub: hub)
        let bob = try await Node.make("bob", hub: hub)
        let alicePairing = PairingService(secureTransport: alice.secure, configuration: .fast)
        let bobPairing = PairingService(secureTransport: bob.secure, configuration: .fast)
        try await alicePairing.start()
        try await bobPairing.start()

        let sa = try await alicePairing.pair(with: bob.id, nickname: "Bob")
        let sb = try await bobPairing.pair(with: alice.id, nickname: "Alice")
        let ea = await Recorder.recording(sa.events)
        let eb = await Recorder.recording(sb.events)
        #expect(try await ea.waitForCode() == eb.waitForCode())
        #expect(await !alice.events.contains(.peerAvailable(bob.id)), "not authenticated before pairing")
        await sa.confirm(codesMatch: true)
        await sb.confirm(codesMatch: true)
        _ = try await ea.waitForOutcome()
        _ = try await eb.waitForOutcome()

        await alice.secure.reconnect(bob.id)
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)
        try await alice.secure.send(Frame(Data("paired!".utf8)), to: bob.id)
        try await bob.waitForMessages(1)
        // Pairing frames never surface as secure-channel messages.
        #expect(await bob.events.received.map(\.0) == [Data("paired!".utf8)])
    }
}

/// Unpairing must win over a pairing ceremony that is still running.
/// Unpairing must win over a pairing ceremony that is still running.
@Suite struct UnpairDuringPairingTests {
    let aliceKey = IdentityKeyPair.generate()
    let bobKey = IdentityKeyPair.generate()

    struct Repair {
        let alice: Node
        let bob: Node
        /// Held so their event loops keep running for the whole test.
        let services: [PairingService]
        let aliceEvents: Recorder<PairingEvent>
        let aliceSession: any PairingSession
        let bobSession: any PairingSession
    }

    /// Alice and Bob are already paired and connected, and start a re-pair.
    func repairing() async throws -> Repair {
        let hub = LoopbackHub()
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey])
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey])
        try await alice.secure.start()
        try await bob.secure.start()
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)
        let alicePairing = PairingService(secureTransport: alice.secure, configuration: .fast)
        let bobPairing = PairingService(secureTransport: bob.secure, configuration: .fast)
        try await alicePairing.start()
        try await bobPairing.start()
        let sa = try await alicePairing.pair(with: bob.id, nickname: "Bob")
        let sb = try await bobPairing.pair(with: alice.id, nickname: "Alice")
        let ea = await Recorder.recording(sa.events)
        let eb = await Recorder.recording(sb.events)
        _ = try await ea.waitForCode()
        _ = try await eb.waitForCode()
        return Repair(alice: alice, bob: bob, services: [alicePairing, bobPairing], aliceEvents: ea, aliceSession: sa, bobSession: sb)
    }

    /// Review 2 finding 1: Alice confirms a re-pair, then unpairs Bob
    /// (remove, then disconnect), then Bob accepts. Alice must not pin Bob
    /// again or get an authenticated session back.
    @Test func unpairingAfterConfirmingARepairWins() async throws {
        let repair = try await repairing()
        let (alice, bob) = (repair.alice, repair.bob)
        await repair.aliceSession.confirm(codesMatch: true)
        try await alice.store.remove(bob.id)
        await alice.secure.disconnect(bob.id)
        await repair.bobSession.confirm(codesMatch: true)
        try await settle()

        #expect(try await repair.aliceEvents.waitForOutcome() == .failed(.cancelled))
        #expect(try await alice.store.peer(for: bob.id) == nil)
        await alice.secure.reconnect(bob.id)
        try await settle()
        #expect(await alice.secure.status(of: bob.id).provenKey == nil)
        withExtendedLifetime(repair.services) {}
    }

    /// Where review 3's test holds one side of the unpair-versus-commit race.
    enum Suspension: String, CaseIterable, Sendable {
        case commitSaveBeforeWrite, commitSaveAfterWrite
        case unpairRemoveBeforeDelete, unpairRemoveAfterDelete, unpairRevocationNotice
    }

    /// Review 3 finding 1, and the invariant of ADR 0100 decision 11: once
    /// `unpair` has started, no pin for the peer survives it and no session
    /// with the peer exists, whichever await either path is suspended at.
    /// Alice has confirmed a re-pair; the test holds one path at one await,
    /// runs the other as far as it can go, then releases.
    @Test(arguments: Suspension.allCases)
    func unpairWinsAtEveryAwait(_ suspension: Suspension) async throws {
        let repair = try await repairing()
        let (alice, bob) = (repair.alice, repair.bob)
        let heardBefore = await alice.events.received.count
        let notice = Gate()
        if suspension == .unpairRevocationNotice {
            await alice.secure.observeRevocations { _ in await notice.wait() }
        }

        switch suspension {
        case .commitSaveBeforeWrite, .commitSaveAfterWrite:
            let point: GatedPairedPeerStore.Point = suspension == .commitSaveBeforeWrite ? .saveBeforeWrite : .saveAfterWrite
            await alice.store.arm(point)
            await repair.aliceSession.confirm(codesMatch: true)
            await repair.bobSession.confirm(codesMatch: true)
            try await eventually("alice's commit is held") { await alice.store.suspended(at: point) == 1 }
            let unpair = Task { try await alice.secure.unpair(bob.id) }
            try await settle()
            #expect(await alice.secure.status(of: bob.id).provenKey == nil, "no session once unpair has started")
            await alice.store.release(point)
            try await unpair.value

        case .unpairRemoveBeforeDelete, .unpairRemoveAfterDelete, .unpairRevocationNotice:
            let point: GatedPairedPeerStore.Point? = switch suspension {
            case .unpairRemoveBeforeDelete: .removeBeforeDelete
            case .unpairRemoveAfterDelete: .removeAfterDelete
            default: nil
            }
            if let point { await alice.store.arm(point) }
            let unpair = Task { try await alice.secure.unpair(bob.id) }
            try await eventually("alice's unpair is held") {
                if let point { return await alice.store.suspended(at: point) == 1 }
                return await notice.waiters == 1
            }
            // While the removal is in progress the pin cannot be used.
            #expect(await alice.secure.status(of: bob.id).provenKey == nil, "no session while unpairing")
            let reconnect = Task { await alice.secure.reconnect(bob.id) }
            await repair.aliceSession.confirm(codesMatch: true)
            await repair.bobSession.confirm(codesMatch: true)
            try await settle()
            #expect(await alice.secure.status(of: bob.id).provenKey == nil, "no new session while unpairing")
            if let point { await alice.store.release(point) } else { await notice.release() }
            try await unpair.value
            await reconnect.value
        }
        try await settle()

        // The invariant, after everything has settled.
        if case .paired = try await repair.aliceEvents.waitForOutcome() { Issue.record("alice re-pinned bob") }
        #expect(try await alice.store.peer(for: bob.id) == nil)
        await alice.secure.reconnect(bob.id)
        try? await bob.secure.send(Frame(Data("still here".utf8)), to: alice.id)
        try await settle()
        #expect(await alice.secure.status(of: bob.id).provenKey == nil)
        #expect(await alice.events.received.count == heardBefore)
        await notice.release()
        withExtendedLifetime(repair.services) {}
    }

    /// Review 2 finding 1, pending save: both owners confirmed and Alice's
    /// save is in flight when she unpairs Bob through `unpair(_:)`, which
    /// runs while the save is still held. Unpairing must still win.
    @Test func unpairingDuringAPendingSaveWins() async throws {
        let repair = try await repairing()
        let (alice, bob) = (repair.alice, repair.bob)
        await alice.store.armSaveGate()
        await repair.aliceSession.confirm(codesMatch: true)
        await repair.bobSession.confirm(codesMatch: true)
        try await eventually("alice's save is in flight") { await alice.store.suspendedSaves == 1 }

        // The unpair's removal waits for the commit holding the pin lock;
        // the commit then sees the revocation and leaves no pin.
        let unpair = Task { try await alice.secure.unpair(bob.id) }
        try await settle()
        await alice.store.releaseSaves()
        try await unpair.value

        #expect(try await repair.aliceEvents.waitForOutcome() == .failed(.cancelled))
        #expect(try await alice.store.peer(for: bob.id) == nil)
        await alice.secure.reconnect(bob.id)
        try await settle()
        #expect(await alice.secure.status(of: bob.id).provenKey == nil)
        withExtendedLifetime(repair.services) {}
    }
}

/// Review 4 finding 2: a device runs one SecureTransport per link type
/// (LocalP2P and Wi-Fi Aware) over one identity and one pinned-peer store.
/// Revocation must reach every one of them, and pairing on any of them.
@Suite struct SharedAuthorityTests {
    let aliceKey = IdentityKeyPair.generate()
    let bobKey = IdentityKeyPair.generate()

    struct TwoLinks {
        let aliceLocal: Node, aliceAware: Node, bobLocal: Node, bobAware: Node
    }

    func connectedOverTwoLinks() async throws -> TwoLinks {
        let local = LoopbackHub()
        let aware = LoopbackHub()
        let aliceLocal = try await Node.make("alice-local", hub: local, identity: aliceKey, pins: [bobKey])
        let aliceAware = try await Node.make("alice-aware", hub: aware, sharing: aliceLocal)
        let bobLocal = try await Node.make("bob-local", hub: local, identity: bobKey, pins: [aliceKey])
        let bobAware = try await Node.make("bob-aware", hub: aware, sharing: bobLocal)
        for node in [aliceLocal, aliceAware, bobLocal, bobAware] { try await node.secure.start() }
        try await aliceLocal.waitForPeer(bobKey.peerID)
        try await aliceAware.waitForPeer(bobKey.peerID)
        try await bobLocal.waitForPeer(aliceKey.peerID)
        try await bobAware.waitForPeer(aliceKey.peerID)
        return TwoLinks(aliceLocal: aliceLocal, aliceAware: aliceAware, bobLocal: bobLocal, bobAware: bobAware)
    }

    /// Unpairing through the LocalP2P transport ends the Wi-Fi Aware session too.
    @Test func unpairingThroughOneTransportEndsTheSessionOnEvery() async throws {
        let links = try await connectedOverTwoLinks()
        let bob = bobKey.peerID
        try await links.aliceLocal.secure.unpair(bob)
        try await settle()

        #expect(try await links.aliceLocal.store.peer(for: bob) == nil)
        #expect(await links.aliceLocal.secure.status(of: bob).provenKey == nil)
        #expect(await links.aliceAware.secure.status(of: bob).provenKey == nil)
        try? await links.bobAware.secure.send(Frame(Data("over wi-fi aware".utf8)), to: aliceKey.peerID)
        try? await links.bobLocal.secure.send(Frame(Data("over localp2p".utf8)), to: aliceKey.peerID)
        try await settle()
        #expect(await links.aliceAware.events.received.isEmpty)
        #expect(await links.aliceLocal.events.received.isEmpty)
    }

    /// Review 4 finding 1: Alice's re-pair commit is held after its write;
    /// a disconnect of Bob completes meanwhile; the peers then try KK while
    /// the save is still held (the lookup would read the just-saved pin).
    /// When the commit resumes it rolls back, and nothing authenticated in
    /// that window may survive, on either transport.
    @Test func aDisconnectDuringAHeldCommitLeavesNoLiveSession() async throws {
        let links = try await connectedOverTwoLinks()
        let (alice, bob) = (aliceKey.peerID, bobKey.peerID)
        let alicePairing = PairingService(secureTransport: links.aliceAware.secure, configuration: .fast)
        let bobPairing = PairingService(secureTransport: links.bobAware.secure, configuration: .fast)
        try await alicePairing.start()
        try await bobPairing.start()
        let sa = try await alicePairing.pair(with: bob, nickname: "Bob")
        let sb = try await bobPairing.pair(with: alice, nickname: "Alice")
        let ea = await Recorder.recording(sa.events)
        _ = try await ea.waitForCode()
        let heardLocal = await links.aliceLocal.events.received.count
        let heardAware = await links.aliceAware.events.received.count

        await links.aliceLocal.store.arm(.saveAfterWrite)
        await sa.confirm(codesMatch: true)
        await sb.confirm(codesMatch: true)
        try await eventually("alice's commit is held after its write") { await links.aliceLocal.store.suspended(at: .saveAfterWrite) == 1 }
        await links.aliceLocal.secure.disconnect(bob)
        await links.aliceLocal.secure.reconnect(bob)
        await links.bobLocal.secure.reconnect(alice)
        await links.bobAware.secure.reconnect(alice)
        try await settle()
        await links.aliceLocal.store.release(.saveAfterWrite)
        try await settle()

        if case .paired = try await ea.waitForOutcome() { Issue.record("the rolled-back commit reported success") }
        #expect(try await links.aliceLocal.store.peer(for: bob) == nil)
        #expect(await links.aliceLocal.secure.status(of: bob).provenKey == nil)
        #expect(await links.aliceAware.secure.status(of: bob).provenKey == nil)
        try? await links.bobLocal.secure.send(Frame(Data("local".utf8)), to: alice)
        try? await links.bobAware.secure.send(Frame(Data("aware".utf8)), to: alice)
        try await settle()
        #expect(await links.aliceLocal.events.received.count == heardLocal)
        #expect(await links.aliceAware.events.received.count == heardAware)
        withExtendedLifetime([alicePairing, bobPairing]) {}
    }

    /// Review 5 finding 1: right after a commit decides its save stands,
    /// another transport revokes Bob (the epoch moves). If the commit was
    /// still in progress at that moment (lookups still blocked by it), the
    /// revocation began before the commit ended, so the commit must roll
    /// back. If the commit had already ended, it stands. Driven by a
    /// synchronous checkpoint, not timing.
    @Test func aRevocationBeforeACommitEndsRollsItBack() async throws {
        let links = try await connectedOverTwoLinks()
        let (alice, bob) = (aliceKey.peerID, bobKey.peerID)
        let authority = links.aliceLocal.authority
        let alicePairing = PairingService(secureTransport: links.aliceAware.secure, configuration: .fast)
        let bobPairing = PairingService(secureTransport: links.bobAware.secure, configuration: .fast)
        try await alicePairing.start()
        try await bobPairing.start()
        let sa = try await alicePairing.pair(with: bob, nickname: "Bob")
        let sb = try await bobPairing.pair(with: alice, nickname: "Alice")
        let ea = await Recorder.recording(sa.events)
        _ = try await ea.waitForCode()

        let commitWasInProgress = Mutex<Bool?>(nil)
        authority.onCheckpoint { checkpoint in
            guard checkpoint == .commitDecided(bob), commitWasInProgress.withLock({ $0 }) == nil else { return }
            commitWasInProgress.withLock { $0 = authority.isBlocked(bob) }
            authority.markRevoked(bob)
        }
        await sa.confirm(codesMatch: true)
        await sb.confirm(codesMatch: true)
        let outcome = try await ea.waitForOutcome()
        authority.onCheckpoint(nil)

        guard let inProgress = commitWasInProgress.withLock({ $0 }) else {
            Issue.record("the checkpoint must be reached")
            return
        }
        if inProgress {
            #expect(outcome == .failed(.cancelled), "a revocation that began before the commit ended must roll it back")
            #expect(try await links.aliceLocal.store.peer(for: bob) == nil)
        } else if case .paired = outcome {
            #expect(try await links.aliceLocal.store.peer(for: bob) != nil)
        } else {
            Issue.record("a commit that ended before the revocation must stand, got \(outcome)")
        }
        withExtendedLifetime([alicePairing, bobPairing]) {}
    }

    /// Both links connected and quiet (every session confirmed), so the next
    /// epoch read for Bob on Alice's authority comes from the test's frame.
    func quietOverTwoLinks() async throws -> TwoLinks {
        let links = try await connectedOverTwoLinks()
        try await eventually("every session confirmed") {
            for (node, peer) in [(links.aliceLocal, bobKey.peerID), (links.aliceAware, bobKey.peerID),
                                 (links.bobLocal, aliceKey.peerID), (links.bobAware, aliceKey.peerID)] {
                if await node.secure.status(of: peer).handshakeInProgress { return false }
            }
            return true
        }
        try await settle()
        return links
    }

    /// Arms Alice's authority so that the first epoch read for `peer` from
    /// now on is immediately followed by a revocation, as if another
    /// transport disconnected the peer at exactly that moment.
    func revokeAtNextEpochRead(_ authority: PinAuthority, _ peer: PeerID) -> Flag {
        let fired = Flag()
        authority.onCheckpoint { checkpoint in
            guard checkpoint == .epochRead(peer), fired.set() else { return }
            authority.markRevoked(peer)
        }
        return fired
    }

    /// Review 5 finding 2, receive: the Wi-Fi Aware transport checks Bob's
    /// epoch for an incoming frame, then the LocalP2P transport revokes Bob.
    /// The frame must not be delivered: revocation has begun.
    @Test func aFrameIsNotDeliveredAfterAnotherTransportRevokes() async throws {
        let links = try await quietOverTwoLinks()
        let (alice, bob) = (aliceKey.peerID, bobKey.peerID)
        let heard = await links.aliceAware.events.received.count
        let fired = revokeAtNextEpochRead(links.aliceLocal.authority, bob)
        try await links.bobAware.secure.send(Frame(Data("after revocation".utf8)), to: alice)
        try await eventually("the revocation fires") { fired.isSet }
        try await settle()
        links.aliceLocal.authority.onCheckpoint(nil)
        #expect(await links.aliceAware.events.received.count == heard)
    }

    /// Review 5 finding 2, send: the same race on the sending side. The
    /// frame must not be sealed under the revoked session.
    @Test func aFrameIsNotSentAfterAnotherTransportRevokes() async throws {
        let links = try await quietOverTwoLinks()
        let (alice, bob) = (aliceKey.peerID, bobKey.peerID)
        let heard = await links.bobAware.events.received.count
        let fired = revokeAtNextEpochRead(links.aliceLocal.authority, bob)
        await #expect(throws: TransportError.peerUnreachable(bob)) {
            try await links.aliceAware.secure.send(Frame(Data("after revocation".utf8)), to: bob)
        }
        links.aliceLocal.authority.onCheckpoint(nil)
        #expect(fired.isSet)
        try await settle()
        #expect(await links.bobAware.events.received.count == heard)
        _ = alice
    }

    /// A re-pair running over the Wi-Fi Aware transport cannot restore a pin
    /// that an unpair through the LocalP2P transport removed.
    @Test func aCommitOnAnotherTransportCannotRestoreTheUnpairedPin() async throws {
        let links = try await connectedOverTwoLinks()
        let (alice, bob) = (aliceKey.peerID, bobKey.peerID)
        let alicePairing = PairingService(secureTransport: links.aliceAware.secure, configuration: .fast)
        let bobPairing = PairingService(secureTransport: links.bobAware.secure, configuration: .fast)
        try await alicePairing.start()
        try await bobPairing.start()
        let sa = try await alicePairing.pair(with: bob, nickname: "Bob")
        let sb = try await bobPairing.pair(with: alice, nickname: "Alice")
        let ea = await Recorder.recording(sa.events)
        _ = try await ea.waitForCode()

        await links.aliceLocal.store.arm(.saveAfterWrite)
        await sa.confirm(codesMatch: true)
        await sb.confirm(codesMatch: true)
        try await eventually("alice's commit is held after its write") { await links.aliceLocal.store.suspended(at: .saveAfterWrite) == 1 }
        let unpair = Task { try await links.aliceLocal.secure.unpair(bob) }
        try await settle()
        await links.aliceLocal.store.release(.saveAfterWrite)
        try await unpair.value
        try await settle()

        if case .paired = try await ea.waitForOutcome() { Issue.record("alice re-pinned bob over the other transport") }
        #expect(try await links.aliceLocal.store.peer(for: bob) == nil)
        await links.aliceAware.secure.reconnect(bob)
        try await settle()
        #expect(await links.aliceAware.secure.status(of: bob).provenKey == nil)
        withExtendedLifetime([alicePairing, bobPairing]) {}
    }
}

/// Issue #32: unpairing must not depend on the network. A pairing ceremony
/// with the peer is running, so unpair's revocation tells it to cancel, and
/// the ceremony's cancel notice to the peer is a network send. With Alice's
/// link stalled, unpair must still finish and the pin must be gone before
/// the stall clears.
@Suite struct UnpairIndependenceTests {
    @Test func unpairFinishesAndDeletesThePinWhileSendsAreStalled() async throws {
        let aliceKey = IdentityKeyPair.generate()
        let bobKey = IdentityKeyPair.generate()
        let hub = LoopbackHub()
        let alice = try await Node.make("alice", hub: hub, identity: aliceKey, pins: [bobKey], gated: true)
        let bob = try await Node.make("bob", hub: hub, identity: bobKey, pins: [aliceKey])
        try await alice.secure.start()
        try await bob.secure.start()
        try await alice.waitForPeer(bob.id)
        try await bob.waitForPeer(alice.id)
        let alicePairing = PairingService(secureTransport: alice.secure, configuration: .fast)
        let bobPairing = PairingService(secureTransport: bob.secure, configuration: .fast)
        try await alicePairing.start()
        try await bobPairing.start()
        let sa = try await alicePairing.pair(with: bob.id, nickname: "Bob")
        let sb = try await bobPairing.pair(with: alice.id, nickname: "Alice")
        let ea = await Recorder.recording(sa.events)
        let eb = await Recorder.recording(sb.events)
        _ = try await ea.waitForCode()
        _ = try await eb.waitForCode()

        let link = try #require(alice.link as? GatedLink)
        await link.armSendGate()
        let finished = Flag()
        let unpair = Task {
            try await alice.secure.unpair(bob.id)
            _ = finished.set()
        }
        try await eventually("unpair finishes while every send is stalled") { finished.isSet }
        #expect(try await alice.store.peer(for: bob.id) == nil)
        #expect(await alice.secure.status(of: bob.id).provenKey == nil)

        await link.releaseSends()
        try await unpair.value
        #expect(try await ea.waitForOutcome() == .failed(.cancelled))
        withExtendedLifetime([alicePairing, bobPairing]) {}
    }
}
