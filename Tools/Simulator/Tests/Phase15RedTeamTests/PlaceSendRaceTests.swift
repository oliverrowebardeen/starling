import Foundation
@testable import PickAPlace
import StarlingChaining
import StarlingCore
import StarlingFakes
import Testing

/// Holds completion after the real secure transport has delivered a query.
/// An audit observer can suspend at exactly this point in production.
private actor QueryCompletionGate: OutboxObserver {
    private var holding = true
    private var waiters: [MessageID: CheckedContinuation<Void, Never>] = [:]
    private(set) var queries: [Envelope] = []

    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {
        guard envelope.body.kind == .query else { return }
        queries.append(envelope)
        if holding { await withCheckedContinuation { waiters[envelope.id] = $0 } }
    }

    func releaseAll() {
        holding = false
        let pending = waiters.values
        waiters = [:]
        for waiter in pending { waiter.resume() }
    }
}

@Suite("P15-F place send completion race", .serialized, .timeLimit(.minutes(3)))
struct PlaceSendRaceTests {
    @Test func authenticatedAnswersCanArriveBeforeTheirQueryIDsAreRecorded() async throws {
        let world = try await PlaceWorld.make()
        let (a, b, c) = (world.phones[0], world.phones[1], world.phones[2])
        await a.service.shutdown()
        let gate = QueryCompletionGate()
        let outbox = Outbox(transport: try #require(a.agent.secureTransport), policy: a.policy, consent: a.consent,
            observer: gate, sequences: InMemorySentSequenceStore(), ledger: a.conversations, now: { P15.date })
        let service = PickAPlaceService(localPeer: a.id, outbox: outbox, pairedPeers: a.peers, candidates: a.staged,
            maps: a.maps, ownerLimits: { .empty }, ledger: a.ledger, conversations: a.conversations, plans: { _ in nil },
            clock: a.clock.clock, configuration: PlacePhone.configuration)
        let collector = Task { for await event in service.events { await a.events.record(event) } }
        defer { Task { await gate.releaseAll(); await service.shutdown(); await world.stop(); collector.cancel() } }
        for hello in await a.agent.received where hello.body.kind == .hello { await service.handle(.message(hello)) }
        await a.relay.attach(service)

        // Use the same parent, planner, staged venue, and real invitees as
        // aShortenedRealPlaceRosterMustCarryIntoTheNextChain.
        let parent = try ChainFixture.parent(me: a.id, attendees: [a.id, b.id, c.id])
        let planner = ChainPlanner(registry: ChainFixture.registry, me: a.id)
        let cards = try ChainFixture.cards([b.id, c.id])
        let row = try #require(planner.suggestions(after: parent.id, in: [parent], settings: ChainFixture.settings,
            cards: cards).first { $0.id == .pickAPlace })
        let start = try planner.begin(row, in: [parent], settings: ChainFixture.settings, cards: cards,
            tap: OwnerTap(at: P15.now), consent: row.consent(approvedAt: P15.now), rules: .empty,
            expiresAt: Timestamp(P15.date.addingTimeInterval(300)))
        var interaction = start.interaction
        try interaction.apply(.started, at: P15.now)
        try await a.events.add(interaction)
        let candidate = try PlaceWorld.candidate()
        await world.seed([candidate])
        await a.staged.stage([candidate], for: interaction.id)
        try await service.start(start.request)
        let conversation = interaction.conversation

        try await P15.eventually("both real queries await post-send completion") { await gate.queries.count == 2 }
        let queries = await gate.queries
        var replies: [Envelope] = []
        for friend in [b, c] {
            try await P15.eventually("real friend answered the held query") {
                await friend.sent(conversation).contains { $0.body.kind == .answer }
            }
            let reply = try #require(await friend.sent(conversation).first { $0.body.kind == .answer })
            replies.append(reply)
            try await P15.eventually("organizer handled the authenticated answer while send was held") {
                await a.relay.handled.contains(reply.id)
            }
        }

        let before = try #require(await service.organized[conversation])
        #expect(before.queryIDs.values.flatMap { $0 }.isEmpty)
        #expect(before.answers.isEmpty)
        #expect(before.phase == .asking && before.waitingOn.count == 2)
        #expect(await a.clock.elapsed == .zero)
        print("P15-F held send: 2 queries delivered, 2 authenticated answers handled, 0 query IDs registered, 0 answers retained")

        await gate.releaseAll()
        try await P15.eventually("both query IDs registered after send completion") {
            await service.organized[conversation]?.queryIDs.values.flatMap { $0 }.count == 2
        }
        try await a.clock.waitForSleeps([.seconds(5), .seconds(20), .seconds(300)])
        let after = try #require(await service.organized[conversation])
        print("P15-F released send: \(after.queryIDs.values.flatMap { $0 }.count) query IDs registered, \(after.answers.count) answers retained, \(after.waitingOn.count) friends still pending")
        #expect(after.answers.count == 2, "Genuine replies must survive arrival before the send completion callback")

        // Positive control: resend the exact same typed answer through the
        // friend's Outbox with a fresh envelope, after IDs are registered.
        // Neither the candidates nor any protocol clock changes.
        for (friend, reply) in zip([b, c], replies) {
            let original = try #require(queries.first { $0.recipient == friend.id })
            guard case .query(let query) = original.body else { Issue.record("Expected place query"); return }
            _ = try await friend.send(reply.body, to: a.id, conversation: conversation,
                context: OutboundContext(answering: query), parent: parent.conversation)
        }
        _ = try await a.wait(.proposed, in: conversation)
        _ = try await b.wait(.proposed, in: conversation)
        _ = try await c.wait(.proposed, in: conversation)
        #expect(await service.organized[conversation]?.answers.count == 2)
        #expect(await a.clock.elapsed == .zero)
        #expect(await b.clock.elapsed == .zero)
        #expect(await c.clock.elapsed == .zero)
        print("P15-F control: identical answers replayed after registration produce all 3 proposal cards at virtual time zero")
    }
}
