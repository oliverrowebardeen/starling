import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

@MainActor
@Suite struct AppModelTests {
    static func services(down: ScriptedDownService?, peers: InMemoryPairedPeerStore?, captured: ConsentCapture? = nil, inbox: AsyncStream<InboxEvent>? = nil) -> AppServices {
        var makeDown: (@Sendable (any ConsentProvider) -> any DownService)?
        if let down {
            makeDown = { consent in
                captured?.set(consent)
                return down
            }
        }
        return AppServices(
            agent: nil,
            rules: InMemoryRulesStore(),
            peers: peers,
            makeDownService: makeDown,
            makePairingSession: { ScriptedPairingSession(code: "123 456", peer: Fixtures.peer("Test")) },
            inboxEvents: inbox,
            notifier: RecordingNotifier(),
            localNetwork: CountingPrompter()
        )
    }

    final class ConsentCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (any ConsentProvider)?
        func set(_ provider: any ConsentProvider) { lock.withLock { value = provider } }
        func get() -> (any ConsentProvider)? { lock.withLock { value } }
    }

    @Test func givesTheDownServiceTheAppsConsentSheet() async {
        let capture = ConsentCapture()
        let app = AppModel(services: Self.services(down: ScriptedDownService(), peers: InMemoryPairedPeerStore(), captured: capture))
        #expect(app.down != nil)
        #expect((capture.get() as? ConsentCoordinator) === app.consent)
    }

    @Test func aNewIntentForgetsConsentApprovals() async throws {
        let maya = Fixtures.peer("Maya")
        let app = AppModel(services: Self.services(down: ScriptedDownService(), peers: InMemoryPairedPeerStore([maya])))
        let disclosure = try ConsentCoordinatorTests.disclosure(to: maya.id)
        let first = Task { await app.consent.requestConsent(for: disclosure) }
        await eventually { app.consent.current != nil }
        app.consent.answer(.approved)
        #expect(await first.value == .approved)
        #expect(await app.consent.requestConsent(for: disclosure) == .approved, "remembered")

        let down = try #require(app.down)
        await down.editByHand()
        await down.goDown()
        #expect(down.phase == .active)

        let second = Task { await app.consent.requestConsent(for: disclosure) }
        await eventually { app.consent.current != nil }
        #expect(app.consent.current != nil, "a new intent asks again")
        app.consent.answer(.declined)
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
