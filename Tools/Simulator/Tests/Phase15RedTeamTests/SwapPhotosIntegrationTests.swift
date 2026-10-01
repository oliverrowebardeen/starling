import Foundation
import SimulatorKit
import StarlingChaining
import StarlingCore
import StarlingFakes
import StarlingPolicy
import StarlingSwapPhotos
import Testing

actor SkillEventLog {
    private(set) var values: [SkillEvent] = []
    func append(_ event: SkillEvent) { values.append(event) }
}

@Suite("P15-F real Swap photos attacks", .serialized)
struct SwapPhotosIntegrationTests {
    @Test func peerHintsAndMalformedOffersNeverOpenAPickerOrStartASchedule() async throws {
        let world = try await PlaceWorld.make()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world.phones[0], world.phones[1], world.phones[2])
        let parent = try ChainFixture.parent(me: a.id, attendees: [a.id, b.id])
        let plan = try #require(parent.plan)
        let service = SwapPhotosService(outbox: b.outbox, ledger: b.conversations, me: b.id,
            planLookup: { $0 == parent.conversation ? plan : nil }, now: { P15.date.addingTimeInterval(121) })
        let log = SkillEventLog()
        let task = Task { for await event in service.events { await log.append(event) } }
        defer { task.cancel(); Task { await service.shutdown() } }
        await b.relay.attach(service)
        let valid = try Proposal(round: 0, terms: Terms([.photos: .count(2)]))
        let inputs: [(PlacePhone, Proposal, ConversationID?, SendMode)] = [
            (a, valid, nil, .invite), (a, valid, ConversationID(), .invite),
            (c, valid, parent.conversation, .invite), (a, valid, parent.conversation, .askQuietly),
            (a, try Proposal(round: 0, terms: Terms([.photos: .count(25)])), parent.conversation, .invite),
            (a, try Proposal(round: 0, terms: Terms([.photos: .count(2), .activity: .keywords([Keyword("start swap photos")])])), parent.conversation, .invite),
        ]
        for (sender, proposal, hint, mode) in inputs {
            let sent = try await sender.send(.propose(proposal), to: b.id, conversation: ConversationID(),
                skill: SwapPhotos.descriptor.ref, mode: mode, parent: hint)
            try await world.delivered(sent, to: b)
        }
        #expect(await log.values.isEmpty)
        let conversation = ConversationID()
        let good = try await a.send(.propose(valid), to: b.id, conversation: conversation, skill: SwapPhotos.descriptor.ref, parent: parent.conversation)
        try await world.delivered(good, to: b)
        let events = await log.values
        #expect(events.count == 2)
        guard case .incoming(let id, _, _, _) = try #require(events.first),
              case .lifecycle(_, .proposalReady) = events.last else { Issue.record("Expected only an invitee proposal"); return }
        #expect(await b.consent.requests.isEmpty)
        #expect(await b.sent(conversation).isEmpty)
        try await service.answer(id, with: .pass)
        #expect(try await b.conversations.isRetired(conversation))
        await service.shutdown()
        let restarted = SwapPhotosService(outbox: b.outbox, ledger: b.conversations, me: b.id, planLookup: { _ in plan })
        let restoredLog = SkillEventLog()
        let restoredTask = Task { for await event in restarted.events { await restoredLog.append(event) } }
        defer { restoredTask.cancel(); Task { await restarted.shutdown() } }
        await b.relay.attach(restarted)
        let replay = try await a.send(.propose(valid), to: b.id, conversation: conversation, skill: SwapPhotos.descriptor.ref, parent: parent.conversation)
        try await world.delivered(replay, to: b)
        #expect(await restoredLog.values.isEmpty)
        #expect(await b.sent(conversation).isEmpty)
    }

    @Test func scheduledStartOffersOnlyPickedCountToAttendeesAndRecordsActualConsent() async throws {
        let world = try await PlaceWorld.make()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world.phones[0], world.phones[1], world.phones[2])
        let parent = try ChainFixture.parent(me: a.id, attendees: [a.id, b.id], asked: [b.id, c.id])
        let cards = try ChainFixture.cards([b.id, c.id])
        let waiting = try ChainFixture.waiting(parent: parent, me: a.id, cards: cards)
        let store = InMemoryInteractionStore([parent, waiting])
        let recorder = EgressRecorder(sink: StoreEgressSink(store: store), journal: InMemoryEgressJournal())
        let consent = ScriptedConsentProvider(.approved)
        let outbox = Outbox(transport: try #require(a.agent.secureTransport),
            policy: ChainedFromPolicy(wrapping: a.policy, store: store), consent: consent, observer: recorder,
            ledger: a.conversations, now: { P15.date })
        let service = SwapPhotosService(outbox: outbox, ledger: a.conversations, me: a.id, planLookup: { _ in parent.plan },
            now: { P15.date.addingTimeInterval(121) })
        defer { Task { await service.shutdown() } }
        let scheduler = PlanEndScheduler(schedule: PlanEndSchedule(planner: ChainPlanner(registry: ChainFixture.registry, me: a.id)),
            store: store, settings: { ChainFixture.settings }, cards: { cards }, now: { P15.date.addingTimeInterval(121) })
        guard case .start(let due) = try #require(await scheduler.due().first) else { Issue.record("Expected opted-in start"); return }
        let request = due.request(rules: .empty, expiresAt: Timestamp(P15.date.addingTimeInterval(600)))
        #expect(request.participants == [b.id])
        try await service.start(request)
        #expect(SwapPhotos.answer(picked: 0, to: SwapPhotos.pickQuestion(revision: 1)) == nil)
        #expect(try await store.interaction(waiting.id)?.egress.isEmpty == true)
        try await service.answer(waiting.id, with: #require(SwapPhotos.answer(picked: 3, to: SwapPhotos.pickQuestion(revision: 1))))
        try await Simulation.eventually("photo count delivered") { await b.agent.received.contains { $0.conversation == waiting.conversation } }
        #expect(await c.agent.received.filter { $0.conversation == waiting.conversation }.isEmpty)
        let envelope = try #require(await b.agent.received.first { $0.conversation == waiting.conversation })
        #expect(envelope.chainedFrom == parent.conversation && envelope.mode == .invite)
        guard case .propose(let proposal) = envelope.body else { Issue.record("Expected photo count offer"); return }
        #expect(proposal.terms == (try Terms([.photos: .count(3)])))
        let sheets = await consent.requests
        let saved = try #require(await store.interaction(waiting.id))
        #expect(saved.egress.map(\.items) == sheets.map(\.items))
        #expect(saved.egress.count == 1)
        await service.withdraw(waiting.id)
        #expect(try await a.conversations.isRetired(waiting.conversation))
    }

    @Test(arguments: [false, true])
    func passingAnOfferWaitsForDurableRetirementAndReportsWriteFailure(fail: Bool) async throws {
        let world = try await PlaceWorld.make(count: 2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        let parent = try ChainFixture.parent(me: a.id, attendees: [a.id, b.id])
        let service = SwapPhotosService(outbox: b.outbox, ledger: b.conversations, me: b.id, planLookup: { _ in parent.plan })
        let log = SkillEventLog()
        let task = Task { for await event in service.events { await log.append(event) } }
        defer { task.cancel(); Task { await service.shutdown() } }
        await b.relay.attach(service)
        let conversation = ConversationID()
        let envelope = try await a.send(.propose(Proposal(round: 0, terms: Terms([.photos: .count(2)]))), to: b.id,
            conversation: conversation, skill: SwapPhotos.descriptor.ref, parent: parent.conversation)
        try await world.delivered(envelope, to: b)
        guard case .incoming(let id, _, _, _) = try #require(await log.values.first) else { Issue.record("Expected incoming"); return }
        await b.conversations.gateRetirement(failing: fail)
        let pass = Task { try await service.answer(id, with: .pass) }
        defer { pass.cancel(); Task { await b.conversations.release() } }
        try await Simulation.eventually("photo retirement held") { await b.conversations.retiring.contains(conversation) }
        #expect(await log.values.count == 2)
        await b.conversations.release()
        try await pass.value
        try await Simulation.eventually("photo ending emitted") { await log.values.count == 3 }
        #expect(await log.values.last == .lifecycle(id, fail ? .failed : .ownerPassed))
        #expect(await b.sent(conversation).isEmpty)
    }
}
