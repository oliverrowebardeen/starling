import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingIdentity
import StarlingTransport
import Testing

/// A Loopback link that silently loses outgoing pairing frames of chosen
/// types, the way a Wi-Fi Aware link loses frames while it is replaced
/// right after the system pairs two phones (ADR 0110, consequences).
actor LossyPairingLink: Transport {
    nonisolated let inner: LoopbackTransport
    nonisolated var kind: TransportKind { inner.kind }
    nonisolated var localPeer: PeerID { inner.localPeer }
    nonisolated var events: AsyncStream<TransportEvent> { inner.events }

    private var losing: [PairingCeremony.MessageType: Int] = [:]
    private(set) var lost = 0
    private(set) var sent: [PairingCeremony.MessageType] = []
    private var bodies: [PairingCeremony.MessageType: Set<Data>] = [:]

    init(_ inner: LoopbackTransport) { self.inner = inner }

    /// Loses the next `count` frames of `type` (`.max` loses all of them).
    func lose(_ type: PairingCeremony.MessageType, count: Int = 1) { losing[type] = count }
    func stopLosing() { losing = [:] }
    func sentCount(_ type: PairingCeremony.MessageType) -> Int { sent.filter { $0 == type }.count }
    /// Different frames of `type` sent; a resend repeats the same bytes.
    func distinctSent(_ type: PairingCeremony.MessageType) -> Int { bodies[type]?.count ?? 0 }

    func start() async throws { try await inner.start() }
    func stop() async { await inner.stop() }

    func send(_ frame: Frame, to peer: PeerID) async throws {
        let type = frame.bytes.first.flatMap(PairingCeremony.MessageType.init(rawValue:))
        if let type {
            sent.append(type)
            bodies[type, default: []].insert(frame.bytes)
            if let left = losing[type], left > 0 {
                losing[type] = left == .max ? left : left - 1
                lost += 1
                return
            }
        }
        try await inner.send(frame, to: peer)
    }
}

/// One phone whose pairing link can lose frames.
struct LossyDevice {
    let identity: IdentityKeyPair
    let store: InMemoryPairedPeerStore
    let link: LossyPairingLink
    let service: PairingService

    var id: PeerID { identity.peerID }

    static func make(hub: LoopbackHub, identity: IdentityKeyPair = .generate(), configuration: PairingConfiguration = .reliable) async throws -> LossyDevice {
        let store = InMemoryPairedPeerStore()
        let link = LossyPairingLink(LoopbackTransport(localPeer: identity.peerID, hub: hub))
        let service = PairingService(authority: PinAuthority(identity: identity, store: store), link: link, configuration: configuration)
        try await service.start()
        return LossyDevice(identity: identity, store: store, link: link, service: service)
    }

    /// Two phones, the XX initiator (lower PeerID) first.
    static func pair(hub: LoopbackHub, configuration: PairingConfiguration = .reliable) async throws -> (initiator: LossyDevice, responder: LossyDevice) {
        let keys = [IdentityKeyPair.generate(), .generate()].sorted { $0.peerID < $1.peerID }
        let a = try await make(hub: hub, identity: keys[0], configuration: configuration)
        let b = try await make(hub: hub, identity: keys[1], configuration: configuration)
        return (a, b)
    }
}

extension PairingConfiguration {
    /// Short timers so a stalled ceremony fails fast, and quick resends.
    static let reliable = PairingConfiguration(
        handshakeTimeout: .seconds(3), confirmationTimeout: .seconds(3), resendInterval: .milliseconds(100)
    )
}

/// Issue #95: on two real iPhones, "Pair a friend" kept failing after the
/// phones paired and the code was entered. Each test reproduces one way a
/// ceremony failed before ADR 0260, over Loopback.
@Suite struct PairingReliabilityTests {
    func confirmBoth(_ ea: Recorder<PairingEvent>, _ eb: Recorder<PairingEvent>, _ sa: any PairingSession, _ sb: any PairingSession) async throws {
        let codeA = try await ea.waitForCode()
        let codeB = try await eb.waitForCode()
        #expect(codeA == codeB)
        await sa.confirm(codesMatch: true)
        await sb.confirm(codesMatch: true)
    }

    func expectPaired(_ events: Recorder<PairingEvent>...) async throws {
        for recorder in events {
            let outcome = try await recorder.waitForOutcome()
            guard case .paired = outcome else {
                Issue.record("expected paired, got \(outcome)")
                return
            }
        }
    }

    /// Every pairing message was sent once; one lost frame stalled the
    /// ceremony until its timeout.
    @Test(arguments: [PairingCeremony.MessageType.hello, .message1, .message2, .message3, .secure])
    func aLostFrameIsSentAgain(_ type: PairingCeremony.MessageType) async throws {
        let hub = LoopbackHub()
        let (a, b) = try await LossyDevice.pair(hub: hub)
        await a.link.lose(type)
        await b.link.lose(type)
        let sa = try await a.service.pair(with: b.id, nickname: "Bob")
        let sb = try await b.service.pair(with: a.id, nickname: "Alice")
        let (ea, eb) = (await Recorder.recording(sa.events), await Recorder.recording(sb.events))
        try await confirmBoth(ea, eb, sa, sb)
        try await expectPaired(ea, eb)
    }

    /// The responder's last `accept` is lost after it committed. Before, the
    /// initiator never heard it and timed out: pairing was one-sided.
    @Test func aLostFinalAcceptIsAnsweredAfterThePeerCommitted() async throws {
        let hub = LoopbackHub()
        let (a, b) = try await LossyDevice.pair(hub: hub)
        let sa = try await a.service.pair(with: b.id, nickname: "Bob")
        let sb = try await b.service.pair(with: a.id, nickname: "Alice")
        let (ea, eb) = (await Recorder.recording(sa.events), await Recorder.recording(sb.events))
        _ = try await ea.waitForCode()
        _ = try await eb.waitForCode()
        await sa.confirm(codesMatch: true)
        try await eventually("a's accept reached b") { await a.link.sentCount(.secure) >= 1 }
        try await settle()
        await b.link.lose(.secure)
        await sb.confirm(codesMatch: true)
        try await expectPaired(ea, eb)
        #expect(try await a.store.all().count == 1)
        #expect(try await b.store.all().count == 1)
    }

    /// Sending before the other phone's link is up threw, and the ceremony
    /// failed at once with "couldn't reach the other phone".
    @Test func aSendBeforeTheLinkIsUpDoesNotEndTheCeremony() async throws {
        let hub = LoopbackHub()
        let (a, b) = try await LossyDevice.pair(hub: hub)
        await hub.partition(a.id, b.id)
        let sa = try await a.service.pair(with: b.id, nickname: "Bob")
        let sb = try await b.service.pair(with: a.id, nickname: "Alice")
        let (ea, eb) = (await Recorder.recording(sa.events), await Recorder.recording(sb.events))
        try await settle()
        await hub.heal(a.id, b.id)
        try await confirmBoth(ea, eb, sa, sb)
        try await expectPaired(ea, eb)
    }

    /// A link that drops and comes back (Wi-Fi Aware replaces links right
    /// after the system pairs) ended the ceremony with "transport failed".
    @Test func aLinkThatDropsAndReturnsDoesNotEndTheCeremony() async throws {
        let hub = LoopbackHub()
        let (a, b) = try await LossyDevice.pair(hub: hub)
        let sa = try await a.service.pair(with: b.id, nickname: "Bob")
        let sb = try await b.service.pair(with: a.id, nickname: "Alice")
        let (ea, eb) = (await Recorder.recording(sa.events), await Recorder.recording(sb.events))
        _ = try await ea.waitForCode()
        await hub.partition(a.id, b.id)
        try await settle()
        await hub.heal(a.id, b.id)
        try await confirmBoth(ea, eb, sa, sb)
        try await expectPaired(ea, eb)
    }

    /// One phone gave up and started over while the other was still in the
    /// old handshake. Before, the old ceremony ignored the new hello, so
    /// every new attempt timed out until both owners restarted together.
    ///
    /// Here the initiator had already sent its nonce, so it does not restart
    /// silently (review round 3 of #104): it fails at once where its owner
    /// sees it, and the next ceremony (the sheet's one automatic rejoin)
    /// pairs.
    @Test func aCeremonyStuckAfterItsNonceEndsVisiblyAndTheNextOnePairs() async throws {
        let hub = LoopbackHub()
        let (a, b) = try await LossyDevice.pair(hub: hub)
        // The initiator's third message never arrives, and neither does the
        // responder's cancel: the initiator is left waiting for the reveal.
        await a.link.lose(.message3, count: .max)
        await b.link.lose(.abort, count: .max)
        let stuck = try await a.service.pair(with: b.id, nickname: "Bob")
        let stuckEvents = await Recorder.recording(stuck.events)
        let stale = try await b.service.pair(with: a.id, nickname: "Alice")
        try await eventually("a sent message 3") { await a.link.sentCount(.message3) >= 1 }
        await stale.cancel()
        await a.link.stopLosing()

        let sb = try await b.service.pair(with: a.id, nickname: "Alice")
        #expect(try await stuckEvents.waitForOutcome() == .failed(.cancelled))
        #expect(await stuckEvents.code == nil)
        try await eventually("a lists b's new request") { await a.service.requests() == [b.id] }
        let sa = try await a.service.pair(with: b.id, nickname: "Bob")
        let (ea, eb) = (await Recorder.recording(sa.events), await Recorder.recording(sb.events))
        try await confirmBoth(ea, eb, sa, sb)
        try await expectPaired(ea, eb)
    }

    /// Only one owner picked the other phone. The other phone lists a
    /// request it can answer, instead of the first owner timing out while
    /// the second searches a list.
    @Test func theOtherPhoneListsARequestToPair() async throws {
        let hub = LoopbackHub()
        let (a, b) = try await LossyDevice.pair(hub: hub)
        _ = try await a.service.pair(with: b.id, nickname: "Bob")
        try await eventually("b lists a's request") { await b.service.requests() == [a.id] }
        let session = try await b.service.pair(with: a.id, nickname: "Alice")
        #expect(await b.service.requests().isEmpty, "answered requests leave the list")
        let events = await Recorder.recording(session.events)
        _ = try await events.waitForCode()
    }

    /// Codex re-review of #104: a phone that joins a request keeps that
    /// request's attempt ID. If it did not, and message 3 was lost, the
    /// initiator starting over only taught the joined phone its new ID
    /// instead of restarting it, and both waited out the timeout.
    @Test func aJoinedRequestKeepsItsAttemptSoAnInitiatorRetryRestartsIt() async throws {
        let hub = LoopbackHub()
        let (initiator, responder) = try await LossyDevice.pair(hub: hub)
        await initiator.link.lose(.message3, count: .max)
        let first = try await initiator.service.pair(with: responder.id, nickname: "Bob")
        try await eventually("the responder lists the request") { await responder.service.requests() == [initiator.id] }
        let joined = try await responder.service.pair(with: initiator.id, nickname: "Alice")
        try await eventually("message 3 was sent and lost") { await initiator.link.sentCount(.message3) >= 1 }
        await first.cancel()
        await initiator.link.stopLosing()

        // Only the initiator retries; the responder's joined ceremony runs on.
        let retry = try await initiator.service.pair(with: responder.id, nickname: "Bob")
        let (ea, eb) = (await Recorder.recording(retry.events), await Recorder.recording(joined.events))
        try await confirmBoth(ea, eb, retry, joined)
        try await expectPaired(ea, eb)
    }

    /// A request is listed only while the other phone keeps asking.
    @Test func aRequestExpiresWhenThePhoneStopsAsking() async throws {
        let hub = LoopbackHub()
        let (a, b) = try await LossyDevice.pair(hub: hub, configuration: PairingConfiguration(
            handshakeTimeout: .seconds(3), confirmationTimeout: .seconds(3), resendInterval: .milliseconds(100), requestLifetime: .milliseconds(300)
        ))
        let session = try await a.service.pair(with: b.id, nickname: "Bob")
        try await eventually("b lists a's request") { await b.service.requests() == [a.id] }
        await session.cancel()
        try await eventually("the request expires") { await b.service.requests().isEmpty }
    }

    /// A phone that has not sent its nonce yet restarts when the other phone
    /// starts over, with a fresh commitment, so a nonce the other side might
    /// have seen is never committed to again.
    @Test func aResponderRestartsBeforeItsNonceWithAFreshCommitment() async throws {
        let hub = LoopbackHub()
        let (a, b) = try await LossyDevice.pair(hub: hub)
        await a.link.lose(.message3, count: .max)
        let first = try await a.service.pair(with: b.id, nickname: "Bob")
        let sb = try await b.service.pair(with: a.id, nickname: "Alice")
        // The initiator has its keys (message 3 went out, and was lost), so
        // its cancel is encrypted and the responder cannot read it.
        try await eventually("a sent message 3") { await a.link.sentCount(.message3) >= 1 }
        await first.cancel()
        await a.link.stopLosing()
        let sa = try await a.service.pair(with: b.id, nickname: "Bob")
        let (ea, eb) = (await Recorder.recording(sa.events), await Recorder.recording(sb.events))
        let code = try await ea.waitForCode()
        #expect(try await eb.waitForCode() == code)
        #expect(await b.link.distinctSent(.message2) == 2, "the responder committed to a fresh nonce")
    }

    /// A ceremony that is never answered still ends, and a link that never
    /// comes back ends it by the timeout, not before.
    @Test func aLinkThatNeverReturnsEndsByTheTimeout() async throws {
        let hub = LoopbackHub()
        let (a, b) = try await LossyDevice.pair(hub: hub, configuration: PairingConfiguration(
            handshakeTimeout: .seconds(1), confirmationTimeout: .milliseconds(500), resendInterval: .milliseconds(100)
        ))
        let sa = try await a.service.pair(with: b.id, nickname: "Bob")
        let sb = try await b.service.pair(with: a.id, nickname: "Alice")
        let (ea, eb) = (await Recorder.recording(sa.events), await Recorder.recording(sb.events))
        _ = try await ea.waitForCode()
        _ = try await eb.waitForCode()
        await hub.partition(a.id, b.id)
        try await settle()
        #expect(await ea.outcome == nil, "a dropped link alone does not end the ceremony")
        #expect(try await ea.waitForOutcome() == .failed(.timedOut))
        #expect(try await a.store.all().isEmpty)
    }

    /// The service sends on every link and listens on all of them, so two
    /// phones meet even when one link between them is down.
    @Test func phonesMeetOnWhicheverLinkWorks() async throws {
        let wifiAware = LoopbackHub()
        let nearby = LoopbackHub()
        let keys = [IdentityKeyPair.generate(), .generate()]
        var services: [PairingService] = []
        var stores: [InMemoryPairedPeerStore] = []
        for key in keys {
            let store = InMemoryPairedPeerStore()
            let links: [any Transport] = [LoopbackTransport(localPeer: key.peerID, hub: wifiAware), LoopbackTransport(localPeer: key.peerID, hub: nearby)]
            let service = PairingService(authority: PinAuthority(identity: key, store: store), links: links, configuration: .reliable)
            try await service.start()
            services.append(service)
            stores.append(store)
        }
        await wifiAware.partition(keys[0].peerID, keys[1].peerID)
        let sa = try await services[0].pair(with: keys[1].peerID, nickname: "Bob")
        let sb = try await services[1].pair(with: keys[0].peerID, nickname: "Alice")
        let (ea, eb) = (await Recorder.recording(sa.events), await Recorder.recording(sb.events))
        // The link comes back halfway: duplicates on both links change nothing.
        _ = try await ea.waitForCode()
        await wifiAware.heal(keys[0].peerID, keys[1].peerID)
        try await confirmBoth(ea, eb, sa, sb)
        try await expectPaired(ea, eb)
        #expect(try await stores[0].all().count == 1)
        #expect(try await stores[1].all().count == 1)
    }

    /// Two finished ceremonies whose replays reach each other stop after a
    /// few: a lingering phone answers a bounded number of times.
    @Test func finishedCeremoniesGoQuiet() async throws {
        // Latency longer than the replay rate limit, as on a real link.
        let hub = LoopbackHub(latency: .milliseconds(60))
        let wire = await recordDeliveries(hub)
        let (a, b) = try await LossyDevice.pair(hub: hub)
        let sa = try await a.service.pair(with: b.id, nickname: "Bob")
        let sb = try await b.service.pair(with: a.id, nickname: "Alice")
        let (ea, eb) = (await Recorder.recording(sa.events), await Recorder.recording(sb.events))
        try await confirmBoth(ea, eb, sa, sb)
        try await expectPaired(ea, eb)
        // Start a replay exchange: a stray frame reaches a finished ceremony.
        try await hub.inject(Frame(Data([PairingCeremony.MessageType.secure.rawValue, 0])), claimedSender: b.id, to: a.id)
        try await Task.sleep(for: .seconds(1))
        let before = await wire.values.count
        try await Task.sleep(for: .seconds(1))
        #expect(await wire.values.count == before, "no frames once the replays are spent")
    }

    /// The diagnostics hook names steps and failures, and never the code.
    @Test func theTraceRecordsStepsButNotTheCode() async throws {
        let hub = LoopbackHub()
        let log = Recorder<PairingTrace>()
        let keys = [IdentityKeyPair.generate(), .generate()]
        var sessions: [any PairingSession] = []
        var services: [PairingService] = []
        for (key, other) in [(keys[0], keys[1]), (keys[1], keys[0])] {
            let service = PairingService(
                authority: PinAuthority(identity: key, store: InMemoryPairedPeerStore()),
                link: LoopbackTransport(localPeer: key.peerID, hub: hub), configuration: .reliable,
                trace: { trace in Task { await log.append(trace) } }
            )
            try await service.start()
            services.append(service)
            sessions.append(try await service.pair(with: other.peerID, nickname: "Friend"))
        }
        let events = await Recorder.recording(sessions[0].events)
        let code = try await events.waitForCode()
        try await eventually("both codes shown") { await log.values.filter { $0.step == .codeShown }.count == 2 }
        let steps = await log.values.map(\.step)
        #expect(steps.contains(.started(initiator: true)))
        #expect(steps.contains(.sent(.message1)))
        #expect(!String(describing: await log.values).contains(code))
        #expect(await log.values.first { $0.step == .codeShown }?.description.hasSuffix(": code shown") == true)
        withExtendedLifetime(services) {}
    }
}

/// Review round 3 of #104 (HIGH). A phone in the middle of two victims is
/// the responder to both. Once a victim has sent its nonce, the middle
/// phone knows that victim's code; if it does not match the other victim's,
/// it holds back its reveal and sends a hello for a new attempt. If that
/// restarted the victim silently with a fresh nonce, the middle phone could
/// keep drawing codes until two matched. A victim gives out one nonce per
/// ceremony and fails visibly instead.
@Suite struct PairingRestartLimitTests {
    @Test func aResponderHoldingBackItsRevealGetsOneNonceAndAVisibleFailure() async throws {
        let hub = LoopbackHub()
        var victimKey = IdentityKeyPair.generate()
        var middleKey = IdentityKeyPair.generate()
        if middleKey.peerID < victimKey.peerID { swap(&victimKey, &middleKey) }
        let victim = try await PairingDevice.make(hub: hub, identity: victimKey, configuration: .reliable)
        let middle = LoopbackTransport(localPeer: middleKey.peerID, hub: hub)
        let inbound = await Recorder.recording(middle.events)
        try await middle.start()

        let session = try await victim.service.pair(with: middleKey.peerID, nickname: "Bob")
        let events = await Recorder.recording(session.events)
        typealias T = PairingCeremony.MessageType
        @Sendable func frames(_ type: T) async -> [Data] {
            await inbound.received.filter { $0.0.first == type.rawValue }.map { Data($0.0.dropFirst()) }
        }
        func hello() throws -> Frame { try Frame(Data([T.hello.rawValue]) + PairingCode.nonce().prefix(8)) }

        // Up to five rounds: answer message 1, read the victim's nonce in
        // message 3, hold back the reveal, and ask for a new attempt.
        try await middle.send(hello(), to: victim.id)
        var answered = 0
        var rounds = 0
        for _ in 0..<5 {
            // Wait for a handshake not answered yet; none means no restart.
            var seen = 0
            for _ in 0..<100 {
                seen = Set(await frames(.message1)).count
                if seen > answered { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard seen > answered else { break }
            answered = seen
            rounds += 1
            var handshake = try NoiseHandshakeState(
                pattern: .xx, initiator: false, prologue: PairingCeremony.prologue,
                localStatic: middleKey.privateKey, remoteStatic: nil
            )
            _ = try handshake.readMessage(try #require(await frames(.message1).last))
            let reply = try handshake.writeMessage(payload: PairingCode.commitment(to: PairingCode.nonce()))
            try await middle.send(Frame(Data([T.message2.rawValue]) + reply), to: victim.id)
            let before = Set(await frames(.message3)).count
            try await eventually("the victim sent its nonce") { Set(await frames(.message3)).count > before }
            try await middle.send(hello(), to: victim.id)
            try await Task.sleep(for: .milliseconds(300))
        }

        #expect(rounds == 1, "the middle phone got one round")
        #expect(Set(await frames(.message3)).count == 1, "one nonce for the whole ceremony")
        #expect(Set(await frames(.message1)).count == 1, "no new handshake after the nonce went out")
        #expect(try await events.waitForOutcome() == .failed(.cancelled), "the owner sees pairing stop")
        #expect(await events.code == nil)
        #expect(try await victim.store.all().isEmpty)
    }
}

/// Holds outgoing aborts while armed, so a ceremony's cancel can be caught
/// mid-send; everything else passes.
actor AbortGateLink: Transport {
    nonisolated let inner: LoopbackTransport
    nonisolated var kind: TransportKind { inner.kind }
    nonisolated var localPeer: PeerID { inner.localPeer }
    nonisolated var events: AsyncStream<TransportEvent> { inner.events }
    private var armed = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(_ inner: LoopbackTransport) { self.inner = inner }

    var holding: Int { held.count }
    func arm() { armed = true }
    func release() {
        armed = false
        for waiter in held { waiter.resume() }
        held = []
    }

    func start() async throws { try await inner.start() }
    func stop() async { await inner.stop() }

    func send(_ frame: Frame, to peer: PeerID) async throws {
        if armed, frame.bytes.first == PairingCeremony.MessageType.abort.rawValue {
            await withCheckedContinuation { held.append($0) }
        }
        try await inner.send(frame, to: peer)
    }
}

/// Review round 3 of #104 (low): two pair calls for one peer that overlap
/// while the first waits on the old ceremony's cancel. Before, the first
/// call then overwrote the second's ceremony, which never heard the other
/// phone again and ran until its timeout. Now the call that installs last
/// cancels whatever another call registered meanwhile.
@Suite struct OverlappingPairCallTests {
    @Test func aCeremonyReplacedMidCancelIsCancelledNotOrphaned() async throws {
        let hub = LoopbackHub()
        let aliceKey = IdentityKeyPair.generate()
        let link = AbortGateLink(LoopbackTransport(localPeer: aliceKey.peerID, hub: hub))
        let alice = PairingService(authority: PinAuthority(identity: aliceKey, store: InMemoryPairedPeerStore()), link: link, configuration: .reliable)
        try await alice.start()
        let bob = try await LossyDevice.make(hub: hub)

        _ = try await alice.pair(with: bob.id, nickname: "Bob")
        await link.arm()
        let first = Task { try await alice.pair(with: bob.id, nickname: "Bob") }
        try await eventually("the old ceremony's cancel is mid-send") { await link.holding == 1 }
        let second = try await alice.pair(with: bob.id, nickname: "Bob")
        let secondEvents = await Recorder.recording(second.events)
        await link.release()
        let winner = try await first.value

        #expect(try await secondEvents.waitForOutcome() == .failed(.cancelled), "replaced, not left running")
        let sb = try await bob.service.pair(with: aliceKey.peerID, nickname: "Alice")
        let (ea, eb) = (await Recorder.recording(winner.events), await Recorder.recording(sb.events))
        let code = try await ea.waitForCode()
        #expect(try await eb.waitForCode() == code)
    }
}
