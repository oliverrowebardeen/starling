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

    init(_ inner: LoopbackTransport) { self.inner = inner }

    /// Loses the next `count` frames of `type` (`.max` loses all of them).
    func lose(_ type: PairingCeremony.MessageType, count: Int = 1) { losing[type] = count }
    func stopLosing() { losing = [:] }
    func sentCount(_ type: PairingCeremony.MessageType) -> Int { sent.filter { $0 == type }.count }

    func start() async throws { try await inner.start() }
    func stop() async { await inner.stop() }

    func send(_ frame: Frame, to peer: PeerID) async throws {
        let type = frame.bytes.first.flatMap(PairingCeremony.MessageType.init(rawValue:))
        if let type {
            sent.append(type)
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
    /// old handshake. The old ceremony ignored the new hello, so every new
    /// attempt timed out until both happened to start over together.
    @Test func aCeremonyStuckInAnOldHandshakeFollowsTheOtherPhoneStartingOver() async throws {
        let hub = LoopbackHub()
        let (a, b) = try await LossyDevice.pair(hub: hub)
        // The initiator's third message never arrives, and neither does the
        // responder's cancel: the initiator is left waiting for the reveal.
        await a.link.lose(.message3, count: .max)
        await b.link.lose(.abort, count: .max)
        let sa = try await a.service.pair(with: b.id, nickname: "Bob")
        let stale = try await b.service.pair(with: a.id, nickname: "Alice")
        try await eventually("a sent message 3") { await a.link.sentCount(.message3) >= 1 }
        await stale.cancel()
        await a.link.stopLosing()

        let sb = try await b.service.pair(with: a.id, nickname: "Alice")
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

    /// A restart after the other phone started over uses fresh nonces: a
    /// nonce the other side has seen is never committed to again.
    @Test func aRestartedHandshakeGivesANewCode() async throws {
        let hub = LoopbackHub()
        let (a, b) = try await LossyDevice.pair(hub: hub)
        await a.link.lose(.message3, count: .max)
        await b.link.lose(.abort, count: .max)
        let sa = try await a.service.pair(with: b.id, nickname: "Bob")
        _ = try await b.service.pair(with: a.id, nickname: "Alice")
        try await eventually("a sent message 3 twice") { await a.link.sentCount(.message3) >= 2 }
        let firstHandshake = await a.link.sentCount(.message1)
        await a.link.stopLosing()
        let sb = try await b.service.pair(with: a.id, nickname: "Alice")
        let (ea, eb) = (await Recorder.recording(sa.events), await Recorder.recording(sb.events))
        let code = try await ea.waitForCode()
        #expect(try await eb.waitForCode() == code)
        #expect(await a.link.sentCount(.message1) > firstHandshake, "the initiator ran a new handshake")
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
        withExtendedLifetime(services) {}
    }
}
