import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

/// Issue #123 (lane F): Compose must not see a friend's fresh card before
/// the skills that start from it do. Otherwise the owner sends right after
/// pairing, Compose counts the friend as supported, and the skill, still on
/// the old card, ends the request unsupported with nothing sent.
@MainActor
@Suite struct HelloOrderTests {
    /// Down for that holds each hello until the test lets it through.
    actor HoldingService: SkillService {
        nonisolated let descriptor = SampleSkills.downFor
        nonisolated let events = AsyncStream<SkillEvent> { _ in }
        let gate = Gate()
        private(set) var holding = false
        private(set) var hellos = 0
        func start(_ request: SkillRequest) async throws {}
        func answer(_ interaction: InteractionID, with answer: OwnerAnswer) async throws {}
        func withdraw(_ interaction: InteractionID) async {}
        func handle(_ event: InboxEvent) async {
            guard case .message(let envelope) = event, case .hello = envelope.body else { return }
            holding = true
            await gate.wait()
            holding = false
            hellos += 1
        }
        func restore(_ interactions: [Interaction]) async {}
        func shutdown() async {}
    }

    @Test func composeSeesAFreshCardOnlyOnceTheSkillsHaveIt() async throws {
        let me = PeerID.random()
        let maya = Fixtures.peer("Maya")
        let (inbox, continuation) = AsyncStream.makeStream(of: InboxEvent.self)
        let skill = HoldingService()
        var services = AppModelTests.services(peers: InMemoryPairedPeerStore([maya]), inbox: inbox, transport: RecordingTransport(localPeer: me))
        services.makeSkills = { _ in [skill] }
        let app = AppModel(services: services)
        await app.start()

        let card = AgentCard.forBuild(skills: [SampleSkills.downFor.ref], usesPSI: true, locality: .onDevice)
        continuation.yield(.message(try Envelope(conversation: ConversationID(), sender: maya.id, recipient: me, sequence: 0,
                                                 sentAt: Timestamp(Date()), body: .hello(card))))
        // The skill has the hello but has not finished with it.
        while await !skill.holding { await Task.yield() }
        for _ in 0..<50 { await Task.yield() }
        #expect(app.cards.card(for: maya.id) == nil, "Compose would count Maya as supported before Down for does")

        await skill.gate.open()
        await eventually { app.cards.card(for: maya.id) == card }
        #expect(app.cards.card(for: maya.id) == card)
        #expect(await skill.hellos == 1)
        await app.shutdown()
    }
}
