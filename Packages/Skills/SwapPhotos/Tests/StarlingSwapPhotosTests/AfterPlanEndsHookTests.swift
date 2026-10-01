import Foundation
import StarlingChaining
import StarlingCore
import StarlingFakes
import StarlingPolicy
import StarlingSwapPhotos
import Synchronization
import Testing

/// The after-plan-ends hook end to end, on two phones wired as the app wires
/// them: the owner's privacy topics in the real policy, ChainedFromPolicy,
/// the egress recorder, and the plan-end scheduler. This test plays the
/// lifecycle coordinator, applying each service event to the store.
@Suite struct AfterPlanEndsHookTests {
    static let swapOn = SkillSettings(flags: SkillFlags(SkillFlags.phase1_5.enabled.union([.swapPhotos])))
    static let registry = try! SkillRegistry([SampleSkills.downFor, SampleSkills.pickAPlace, SwapPhotos.descriptor])
    static let cards: [PeerID: AgentCard] = [
        Fixtures.maya: try! AgentCard(model: .onDevice, capabilities: [], skills: registry.descriptors.map(\.ref)),
        Fixtures.jake: try! AgentCard(model: .onDevice, capabilities: [], skills: registry.descriptors.map(\.ref)),
    ]

    final class Clock: Sendable {
        private let time: Mutex<Date>
        init(_ start: Date) { time = Mutex(start) }
        var now: Date { time.withLock { $0 } }
        func set(_ date: Date) { time.withLock { $0 = date } }
    }

    /// A Down for… plan on my phone, planned by minute 4, conversation and
    /// plan matching `Fixtures.plan`.
    static func plannedDownFor() throws -> Interaction {
        var plan = Interaction(conversation: Fixtures.parentConversation, skill: SampleSkills.downFor.ref, role: .initiator,
                               participants: [Fixtures.maya, Fixtures.jake], createdAt: Fixtures.at(minutes: 0))
        try plan.apply(.started, at: Fixtures.at(minutes: 1))
        let terms = try Terms([.activity: .keywords([try Keyword("boba")])])
        try plan.apply(.proposalReady(SkillProposal(revision: 1, participants: [Fixtures.me, Fixtures.maya, Fixtures.jake], terms: terms, plan: Fixtures.plan)),
                       at: Fixtures.at(minutes: 2))
        try plan.apply(.ownerAccepted(revision: 1), at: Fixtures.at(minutes: 3))
        try plan.apply(.everyoneConfirmed(revision: 1), at: Fixtures.at(minutes: 4))
        plan.record(.plan(Fixtures.plan))
        return plan
    }

    /// Applies the next `count` service events to the store, as the
    /// coordinator would, and returns them.
    static func coordinate(_ count: Int, from iterator: inout AsyncStream<SkillEvent>.Iterator, into store: InMemoryInteractionStore, at time: Timestamp) async throws -> [SkillEvent] {
        var seen: [SkillEvent] = []
        while seen.count < count, let event = await iterator.next() {
            seen.append(event)
            if case .lifecycle(let id, let lifecycle) = event, var interaction = try await store.interaction(id) {
                try interaction.apply(lifecycle, at: time)
                try await store.save(interaction)
            }
        }
        return seen
    }

    @Test func swapPhotosStartsWhenThePlanEndsOnlyBecauseTheOwnerOptedIn() async throws {
        let clock = Clock(Fixtures.date(minutes: 5))
        let plan = try Self.plannedDownFor()
        let store = InMemoryInteractionStore([plan])
        let planner = ChainPlanner(registry: Self.registry, me: Fixtures.me)
        let schedule = PlanEndSchedule(planner: planner)
        let scheduler = PlanEndScheduler(schedule: schedule, store: store, settings: { Self.swapOn }, cards: { Self.cards }, now: { clock.now })

        // My phone's egress path.
        let transport = RecordingTransport(localPeer: Fixtures.me)
        let consent = ScriptedConsentProvider(.approved)
        let policy = DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty, disclosure: Self.swapOn.privacy.disclosureRules))
        let recorder = EgressRecorder(sink: StoreEgressSink(store: store), journal: InMemoryEgressJournal(), now: { clock.now })
        let ledger = InMemoryConversationLedger()
        let outbox = Outbox(transport: transport, policy: ChainedFromPolicy(wrapping: policy, store: store), consent: consent,
                            observer: recorder, ledger: ledger, now: { clock.now })
        let service = SwapPhotosService(outbox: outbox, ledger: ledger, me: Fixtures.me, planLookup: { _ in Fixtures.plan }, now: { clock.now })
        var events = service.events.makeAsyncIterator()

        // The plan ends with no opt-in: nothing starts.
        clock.set(Fixtures.afterTonight)
        #expect(try await scheduler.due().isEmpty)
        clock.set(Fixtures.date(minutes: 6))

        // It's a plan: the owner turns on "Swap photos after" and approves
        // what it adds (photos, photo access).
        let row = try #require(planner.suggestions(after: plan.id, in: [plan], settings: Self.swapOn, cards: Self.cards).first { $0.id == .swapPhotos })
        #expect(row.adds == SkillExposure(topics: [.photos], permissions: [.photoLibrary]))
        let tap = OwnerTap(at: Timestamp(clock.now))
        let waiting = try planner.optIn(row, in: [plan], settings: Self.swapOn, cards: Self.cards, tap: tap, consent: row.consent(approvedAt: tap.at))
        try await store.save(waiting)

        // Before the plan ends, nothing is due, and nothing has asked for photos.
        clock.set(Fixtures.date(minutes: 209))
        #expect(try await scheduler.due().isEmpty)

        // The plan ends: the scheduler hands the link over and the
        // coordinator starts it.
        clock.set(Fixtures.afterTonight)
        let due = try await scheduler.due()
        guard case .start(let start) = try #require(due.first) else {
            Issue.record("expected a start, got \(due)")
            return
        }
        // The coordinator applies .started, then calls the service.
        var link = try #require(try await store.interaction(waiting.id))
        try link.apply(.started, at: Timestamp(clock.now))
        try await store.save(link)
        try await service.start(start.request(rules: .empty, expiresAt: Timestamp(clock.now.addingTimeInterval(24 * 3600))))
        let first = try await Self.coordinate(1, from: &events, into: store, at: Timestamp(clock.now))
        let question = SwapPhotos.pickQuestion(revision: 1)
        #expect(first == [.lifecycle(waiting.id, .ownerNeeded(question))])
        #expect(try await store.interaction(waiting.id)?.state == .awaitingOwner)
        #expect(await transport.sent.isEmpty)

        // The owner picks three photos in the system picker.
        try await service.answer(waiting.id, with: try #require(SwapPhotos.answer(picked: 3, to: question)))
        _ = try await Self.coordinate(1, from: &events, into: store, at: Timestamp(clock.now))

        // Photos is an Ask me topic: a sheet per friend, then the offers.
        let sheets = await consent.requests
        #expect(sheets.map(\.recipient) == [Fixtures.maya, Fixtures.jake])
        let sent = try await transport.sent.map { try EnvelopeCodec().decode($0.frame.bytes) }
        #expect(sent.allSatisfy { $0.chainedFrom == plan.conversation && $0.conversation == waiting.conversation })

        // What left the phone equals what the sheets showed, on the link.
        link = try #require(try await store.interaction(waiting.id))
        #expect(link.state == .negotiating)
        #expect(link.egress.map(\.items) == sheets.map(\.items))
        let timeline = try #require(PlanTimeline(for: plan.id, in: try await store.all(), registry: Self.registry))
        #expect(timeline.entries.map(\.origin) == [.plan, .chained(.afterPlanEnds, optedInAt: tap.at)])
        #expect(timeline.whatLeft.shared.map(\.topic) == [.photos])
        #expect(timeline.whatLeft.shared.first?.values == [.count(3)])

        // Maya's phone: the offer makes a card under Needs you and nothing
        // else. It does not start Swap photos there, open the picker, or ask
        // for any permission.
        let mayaTransport = RecordingTransport(localPeer: Fixtures.maya)
        let mayaConsent = ScriptedConsentProvider(.approved)
        let mayaLedger = InMemoryConversationLedger()
        let mayaOutbox = Outbox(transport: mayaTransport, policy: FixedPolicyEngine(.allow), consent: mayaConsent, ledger: mayaLedger, now: { clock.now })
        let maya = SwapPhotosService(outbox: mayaOutbox, ledger: mayaLedger, me: Fixtures.maya, planLookup: { $0 == Fixtures.parentConversation ? Fixtures.plan : nil },
                                     now: { clock.now })
        let inbox = Inbox(localPeer: Fixtures.maya, now: { clock.now })
        for frame in await transport.sent where frame.peer == Fixtures.maya {
            await maya.handle(await inbox.process(.received(frame.frame, from: Fixtures.me)))
        }
        await maya.shutdown()
        var mayaEvents: [SkillEvent] = []
        for await event in maya.events { mayaEvents.append(event) }
        #expect(mayaEvents.count == 2)
        guard case .incoming(_, _, let from, let chainedFrom) = mayaEvents.first else {
            Issue.record("expected an incoming interaction, got \(mayaEvents)")
            return
        }
        #expect(from == Fixtures.me && chainedFrom == plan.conversation)
        guard case .lifecycle(_, .proposalReady) = mayaEvents.last else {
            Issue.record("expected only a proposal card, got \(mayaEvents)")
            return
        }
        #expect(await mayaConsent.requests.isEmpty)
        #expect(await mayaTransport.sent.isEmpty)
    }
}
