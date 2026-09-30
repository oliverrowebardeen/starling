import CryptoKit
import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingIdentity
import StarlingTransport
import Testing

/// One phone in a pairing test: identity, store, raw link, and the service.
struct PairingDevice {
    let identity: IdentityKeyPair
    let store: InMemoryPairedPeerStore
    let link: LoopbackTransport
    let service: PairingService

    var id: PeerID { identity.peerID }

    static func make(hub: LoopbackHub, identity: IdentityKeyPair = .generate(), configuration: PairingConfiguration = .fast) async throws -> PairingDevice {
        let store = InMemoryPairedPeerStore()
        let link = LoopbackTransport(localPeer: identity.peerID, hub: hub)
        let service = PairingService(identity: identity, store: store, link: link, configuration: configuration)
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
        let service = PairingService(identity: identity, store: InMemoryPairedPeerStore(), link: LoopbackTransport(localPeer: identity.peerID, hub: hub))
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
        let alicePairing = PairingService(identity: alice.identity, store: alice.store, link: alice.secure.pairingLink, configuration: .fast)
        let bobPairing = PairingService(identity: bob.identity, store: bob.store, link: bob.secure.pairingLink, configuration: .fast)
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
