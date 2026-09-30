import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

@MainActor
@Suite struct AppModelTests {
    static func services(down: ScriptedDownService?, peers: InMemoryPairedPeerStore?, captured: ConsentCapture? = nil) -> AppServices {
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
        down.editByHand()
        await down.goDown()
        #expect(down.phase == .active)

        let second = Task { await app.consent.requestConsent(for: disclosure) }
        await eventually { app.consent.current != nil }
        #expect(app.consent.current != nil, "a new intent asks again")
        app.consent.answer(.declined)
        #expect(await second.value == .declined)
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
