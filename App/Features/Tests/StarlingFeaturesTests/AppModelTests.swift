import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

/// A Down service that counts shutdowns, like lane F's DownNegotiator.
actor StoppableScriptedDown: StoppableDownService {
    nonisolated let events: AsyncStream<DownEvent> = AsyncStream { _ in }
    private(set) var shutdowns = 0
    func setIntent(_ intent: DownIntent) async throws {}
    func clearIntent() async {}
    func handle(_ event: InboxEvent) async {}
    func shutdown() async { shutdowns += 1 }
}

@MainActor
@Suite struct AppModelTests {
    static func services(
        down: (any DownService)?,
        peers: InMemoryPairedPeerStore?,
        captured: OutboxCapture? = nil,
        inbox: AsyncStream<InboxEvent>? = nil,
        transport: RecordingTransport = RecordingTransport(),
        locality: ModelLocality? = nil
    ) -> AppServices {
        var makeDown: (@Sendable (Outbox) -> any DownService)?
        if let down {
            makeDown = { outbox in
                captured?.set(outbox)
                return down
            }
        }
        return AppServices(
            agent: nil,
            rules: InMemoryRulesStore(),
            peers: peers,
            makeDownService: makeDown,
            pairing: PairingModelTests.scripted().directory,
            inboxEvents: inbox,
            makePolicy: { _ in FixedPolicyEngine(.allow) },
            transport: transport,
            agentLocality: locality,
            notifier: RecordingNotifier(),
            localNetwork: CountingPrompter()
        )
    }

    final class OutboxCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Outbox?
        func set(_ outbox: Outbox) { lock.withLock { value = outbox } }
        func get() -> Outbox? { lock.withLock { value } }
    }

    @Test func buildsTheDownServiceOnTheAppsOutbox() async {
        let capture = OutboxCapture()
        let app = AppModel(services: Self.services(down: ScriptedDownService(), peers: InMemoryPairedPeerStore(), captured: capture))
        #expect(app.down != nil)
        #expect(capture.get() === app.outbox)
    }

    @Test func noDownWithoutAnOutbox() {
        var services = Self.services(down: ScriptedDownService(), peers: InMemoryPairedPeerStore())
        services.transport = nil
        #expect(AppModel(services: services).down == nil)
    }

    @Test func startStartsTheTransportAndShutdownStopsEverything() async {
        let transport = RecordingTransport()
        let down = StoppableScriptedDown()
        let app = AppModel(services: Self.services(down: down, peers: InMemoryPairedPeerStore(), transport: transport))
        await app.start()
        #expect(await transport.isStarted)
        await app.shutdown()
        #expect(await down.shutdowns == 1)
        #expect(await transport.isStarted == false)
    }

    /// Lane F: "Down does not send hello; the app's link layer does."
    @Test func greetsEachPeerThatBecomesAvailableWithTheAgentCard() async throws {
        let transport = RecordingTransport()
        let down = ScriptedDownService()
        let (inbox, continuation) = AsyncStream.makeStream(of: InboxEvent.self)
        let app = AppModel(services: Self.services(down: down, peers: InMemoryPairedPeerStore(), inbox: inbox, transport: transport, locality: .onDevice))
        await app.start()
        let friend = PeerID.random()
        continuation.yield(.peerAvailable(friend))

        for _ in 0..<2000 where await transport.sent.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        let sent = try #require(await transport.sent.first)
        let card = try #require(app.agentCard)
        #expect(sent.peer == friend)
        #expect(try EnvelopeCodec().decode(sent.frame.bytes).body == .hello(card))
        #expect(await down.handled == [.peerAvailable(friend)], "the event still reaches Down")
    }

    /// Codex review of PR #42 (finding 2): a build without Down must not
    /// advertise it, or a friend's Down starts a negotiation it never answers.
    @Test func theCardOffersDownOnlyWhenTheBuildRunsIt() {
        let withDown = AppModel(services: Self.services(down: ScriptedDownService(), peers: InMemoryPairedPeerStore(), locality: .onDevice))
        #expect(withDown.agentCard?.capabilities.contains(.down) == true)
        #expect(withDown.agentCard?.capabilities.contains(.psi) == true)

        let withoutDown = AppModel(services: Self.services(down: nil, peers: InMemoryPairedPeerStore(), locality: .onDevice))
        #expect(withoutDown.down == nil)
        let card = withoutDown.agentCard
        #expect(card != nil, "it still greets friends, with the model's location")
        #expect(card?.capabilities.contains(.down) == false)
        #expect(card?.capabilities.contains(.psi) == false)
        #expect(card?.model == .onDevice)
    }

    @Test func aNewIntentForgetsConsentApprovals() async throws {
        let maya = Fixtures.peer("Maya")
        let app = AppModel(services: Self.services(down: ScriptedDownService(), peers: InMemoryPairedPeerStore([maya])))
        let disclosure = try ConsentCoordinatorTests.disclosure(to: maya.id)
        let first = Task { await app.consent.requestConsent(for: disclosure) }
        await eventually { app.consent.current != nil }
        app.consent.answerCurrent(.approved)
        #expect(await first.value == .approved)
        #expect(await app.consent.requestConsent(for: disclosure) == .approved, "remembered")

        let down = try #require(app.down)
        await down.editByHand()
        await down.goDown()
        #expect(down.phase == .active)

        let second = Task { await app.consent.requestConsent(for: disclosure) }
        await eventually { app.consent.current != nil }
        #expect(app.consent.current != nil, "a new intent asks again")
        app.consent.answerCurrent(.declined)
        #expect(await second.value == .declined)
    }

    @Test func routesEveryInboxEventToTheDownServiceInOrder() async throws {
        let down = ScriptedDownService()
        let (inbox, continuation) = AsyncStream.makeStream(of: InboxEvent.self)
        let app = AppModel(services: Self.services(down: down, peers: InMemoryPairedPeerStore(), inbox: inbox))
        await app.start()

        let friend = PeerID.random()
        let envelope = try Envelope(
            conversation: ConversationID(), sender: friend, recipient: .random(), sequence: 0,
            sentAt: Timestamp(Fixtures.noon), body: .propose(try Proposal(round: 0, terms: .empty))
        )
        let events: [InboxEvent] = [.peerAvailable(friend), .message(envelope), .dropped(from: friend, reason: .replay), .peerUnavailable(friend)]
        events.forEach { continuation.yield($0) }

        for _ in 0..<2000 where await down.handled.count < events.count {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await down.handled == events)
    }

    @Test func friendsSeeReachabilityEvenWithoutDown() async {
        let maya = Fixtures.peer("Maya")
        let (inbox, continuation) = AsyncStream.makeStream(of: InboxEvent.self)
        let app = AppModel(services: Self.services(down: nil, peers: InMemoryPairedPeerStore([maya]), inbox: inbox))
        #expect(app.down == nil)
        await app.start()
        continuation.yield(.peerAvailable(maya.id))
        await eventually { app.friends?.isReachable(maya.id) == true }
        #expect(app.friends?.isReachable(maya.id) == true)
    }

    /// Lane E1: each PairingService starts after its transport.
    @Test func afterStartRunsOnceTheTransportHasStarted() async {
        let transport = RecordingTransport()
        let sawStarted = Recorder<Bool>()
        var services = Self.services(down: nil, peers: InMemoryPairedPeerStore(), transport: transport)
        services.afterStart = { await sawStarted.record(await transport.isStarted) }
        let app = AppModel(services: services)
        await app.start()
        #expect(await sawStarted.values == [true])
    }

    @Test func featuresMissingFromTheBuildAreNil() {
        let app = AppModel(services: Self.services(down: nil, peers: nil))
        #expect(app.down == nil)
        #expect(app.friends == nil)
        #expect(app.makePairing() == nil)
    }

    @Test func startLoadsRulesAndFriends() async {
        let maya = Fixtures.peer("Maya")
        let app = AppModel(services: Self.services(down: ScriptedDownService(), peers: InMemoryPairedPeerStore([maya])))
        await app.start()
        #expect(app.rulesEditor.phase == .writing)
        #expect(app.friends?.friends == [maya])
    }
}
