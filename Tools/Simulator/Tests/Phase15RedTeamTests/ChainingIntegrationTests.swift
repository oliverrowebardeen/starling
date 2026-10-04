import Foundation
import PickAPlace
import SimulatorKit
import StarlingChaining
import StarlingCore
import StarlingFakes
import StarlingPolicy
import StarlingSwapPhotos
import Testing

enum ChainFixture {
    static let registry = try! SkillRegistry([SampleSkills.downFor, SampleSkills.findATime, PickAPlaceSkill.descriptor, SwapPhotos.descriptor])
    static let settings = SkillSettings(flags: P15.allFlags)
    static func parent(me: PeerID, attendees: [PeerID], asked: [PeerID]? = nil) throws -> Interaction {
        var interaction = Interaction(skill: SampleSkills.downFor.ref, role: .initiator,
            participants: asked ?? attendees.filter { $0 != me }, createdAt: P15.now)
        try interaction.apply(.started, at: P15.now)
        let time = try TimeSlot(start: P15.date.addingTimeInterval(60), end: P15.date.addingTimeInterval(120))
        let plan = try Plan(origin: interaction.conversation, attendees: Attendees(attendees), activity: Keyword("boba"), time: time)
        let proposal = SkillProposal(revision: 1, participants: attendees, terms: try Terms([.activity: .keywords([Keyword("boba")])]), plan: plan)
        try interaction.apply(.proposalReady(proposal), at: P15.now)
        try interaction.apply(.ownerAccepted(revision: 1), at: P15.now)
        try interaction.apply(.everyoneConfirmed(revision: 1), at: P15.now)
        interaction.record(.plan(plan))
        return interaction
    }
    static func cards(_ peers: [PeerID]) throws -> [PeerID: AgentCard] {
        Dictionary(uniqueKeysWithValues: try peers.map { ($0, try P15.card(registry.descriptors.map(\.ref))) })
    }
    static func waiting(parent: Interaction, me: PeerID, cards: [PeerID: AgentCard]) throws -> Interaction {
        let planner = ChainPlanner(registry: registry, me: me)
        let row = try #require(planner.suggestions(after: parent.id, in: [parent], settings: settings, cards: cards).first { $0.id == .swapPhotos })
        return try planner.optIn(row, in: [parent], settings: settings, cards: cards, tap: OwnerTap(at: P15.now), consent: row.consent(approvedAt: P15.now))
    }
}

@Suite("P15-F real chaining attacks", .serialized)
struct ChainingIntegrationTests {
    @Test func currentAttendeesBoundRequestsAndConsentIsRecheckedAtTheTap() throws {
        let parent = try ChainFixture.parent(me: P15.alice, attendees: [P15.alice, P15.bob], asked: [P15.bob, P15.eve])
        let planner = ChainPlanner(registry: ChainFixture.registry, me: P15.alice)
        let cards = try ChainFixture.cards([P15.bob, P15.eve])
        let row = try #require(planner.suggestions(after: parent.id, in: [parent], settings: ChainFixture.settings, cards: cards).first { $0.id == .pickAPlace })
        #expect(row.participants == [P15.bob])
        #expect(throws: ChainError.consentRequired(row.adds)) {
            try planner.begin(row, in: [parent], settings: ChainFixture.settings, cards: cards, tap: OwnerTap(at: P15.now),
                consent: nil, rules: .empty, expiresAt: P15.now)
        }
        let consent = row.consent(approvedAt: P15.now)
        let request = try planner.begin(row, in: [parent], settings: ChainFixture.settings, cards: cards, tap: OwnerTap(at: P15.now),
            consent: consent, rules: .empty, expiresAt: P15.now).request
        #expect(request.participants == [P15.bob] && request.intent.audience == .picked([P15.bob]) && request.intent.mode == .invite)
        for version: SkillVersion? in [nil, SkillVersion(2)] {
            var changed = cards
            changed[P15.bob] = try P15.card(version.map { [SkillRef(.pickAPlace, $0)] } ?? [])
            #expect(!planner.suggestions(after: parent.id, in: [parent], settings: ChainFixture.settings, cards: changed).contains { $0.id == .pickAPlace })
            #expect(throws: ChainError.notOffered(.pickAPlace)) {
                try planner.begin(row, in: [parent], settings: ChainFixture.settings, cards: changed, tap: OwnerTap(at: P15.now),
                    consent: consent, rules: .empty, expiresAt: P15.now)
            }
        }
        let never = SkillSettings(flags: P15.allFlags, privacy: try PrivacySettings([.place: .never]))
        #expect(throws: ChainError.notOffered(.pickAPlace)) {
            try planner.begin(row, in: [parent], settings: never, cards: cards, tap: OwnerTap(at: P15.now),
                consent: consent, rules: .empty, expiresAt: P15.now)
        }
    }

    @Test(arguments: [false, true])
    func aShortenedRealPlaceRosterMustCarryIntoTheNextChain(losingFirstAnswer: Bool) async throws {
        let world = try await PlaceWorld.make()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world.phones[0], world.phones[1], world.phones[2])
        let parent = try ChainFixture.parent(me: a.id, attendees: [a.id, b.id, c.id])
        let planner = ChainPlanner(registry: ChainFixture.registry, me: a.id)
        let cards = try ChainFixture.cards([b.id, c.id])
        let row = try #require(planner.suggestions(after: parent.id, in: [parent], settings: ChainFixture.settings, cards: cards).first { $0.id == .pickAPlace })
        let start = try planner.begin(row, in: [parent], settings: ChainFixture.settings, cards: cards, tap: OwnerTap(at: P15.now),
            consent: row.consent(approvedAt: P15.now), rules: .empty, expiresAt: Timestamp(P15.date.addingTimeInterval(300)))
        var interaction = start.interaction
        try interaction.apply(.started, at: P15.now)
        try await a.events.add(interaction)
        let candidate = try PlaceWorld.candidate()
        await world.seed([candidate])
        if losingFirstAnswer { await a.relay.loseNextAnswer() }
        await a.staged.stage([candidate], for: interaction.id)
        try await a.service.start(start.request)
        let invited = try await c.wait(.proposed, in: interaction.conversation, retrying: a)
        if losingFirstAnswer {
            #expect(await a.relay.lostAnswers.count == 1)
            #expect(await a.clock.elapsed > .zero)
        }
        _ = try await b.wait(.proposed, in: interaction.conversation)
        try await c.service.answer(invited.id, with: .pass)
        try await b.accept(interaction.conversation)
        _ = try await b.wait(.confirmed, in: interaction.conversation)
        try await a.accept(interaction.conversation)
        let acceptance = try #require(await b.sent(interaction.conversation).first { $0.body.kind == .accept })
        try await world.delivered(acceptance, to: a)
        let deadline = try #require(await a.ledger.deadlines(for: interaction.conversation)?.confirmDeadline)
        let confirmAt = Duration.seconds(deadline.timeIntervalSince(P15.date))
        try await a.clock.waitForSleeps([confirmAt, confirmAt + PlacePhone.configuration.confirmWindow])
        await a.clock.advance(to: confirmAt)
        _ = try await a.wait(.planned, in: interaction.conversation)
        let conversation = interaction.conversation
        try await P15.eventually("real place service publishes final attendees") {
            (try? await a.events.interaction(conversation)?.artifacts.contains(.attendees(Attendees([a.id, b.id])))) == true
        }
        let finished = try #require(await a.events.interaction(interaction.conversation))
        let updated = try #require(planner.parent(parent, updatedBy: finished))
        #expect(updated.plan?.attendees.peers == [a.id, b.id])
        let photos = try #require(planner.suggestions(after: updated.id, in: [updated, finished], settings: ChainFixture.settings, cards: cards).first { $0.id == .swapPhotos })
        #expect(photos.participants == [b.id])
    }

    @Test func anExcludedOriginalInviteeCannotAttachARequestToThePlan() throws {
        let parent = try ChainFixture.parent(me: P15.alice, attendees: [P15.alice, P15.bob], asked: [P15.bob, P15.eve])
        #expect(IncomingChain.timelineParent(chainedFrom: parent.conversation, sender: P15.bob, interactions: [parent]) == parent.conversation)
        #expect(IncomingChain.timelineParent(chainedFrom: ConversationID(), sender: P15.bob, interactions: [parent]) == nil)
        #expect(IncomingChain.timelineParent(chainedFrom: parent.conversation, sender: P15.eve, interactions: [parent]) == nil)
    }

    @Test func scheduledOptOutAndChangedCapabilitiesSurviveStoreReplacement() async throws {
        let parent = try ChainFixture.parent(me: P15.alice, attendees: [P15.alice, P15.bob])
        let cards = try ChainFixture.cards([P15.bob])
        let waiting = try P15.restart(ChainFixture.waiting(parent: parent, me: P15.alice, cards: cards))
        let store = InMemoryInteractionStore([parent, waiting])
        let planner = ChainPlanner(registry: ChainFixture.registry, me: P15.alice)
        let schedule = PlanEndSchedule(planner: planner)
        let scheduler = PlanEndScheduler(schedule: schedule, store: store, settings: { ChainFixture.settings }, cards: { cards },
            now: { P15.date.addingTimeInterval(121) })
        let due = try #require(await scheduler.due().first)
        #expect(due.isCurrent(waiting))
        try await store.remove(planner.optOut(waiting, tap: OwnerTap(at: P15.now)))
        #expect(try await scheduler.claim(due) == nil)
        let restarted = PlanEndScheduler(schedule: schedule, store: store, settings: { ChainFixture.settings }, cards: { cards },
            now: { P15.date.addingTimeInterval(122) })
        #expect(try await restarted.due().isEmpty)
        let blocked = SkillSettings(flags: P15.allFlags, privacy: try PrivacySettings([.photos: .never]))
        #expect(schedule.check(at: P15.date.addingTimeInterval(121), interactions: [parent, waiting], settings: blocked, cards: cards) == [.cancel(waiting, .blockedByPrivacy)])
        #expect(schedule.check(at: P15.date.addingTimeInterval(121), interactions: [parent, waiting], settings: ChainFixture.settings, cards: [:]) == [.cancel(waiting, .unsupported)])
        var incoming = Interaction(skill: SwapPhotos.descriptor.ref, role: .invitee, participants: [P15.bob], createdAt: P15.now)
        try incoming.setFriendChainHint(parent.conversation)
        #expect(schedule.check(at: P15.date.addingTimeInterval(121), interactions: [parent, incoming], settings: ChainFixture.settings, cards: cards).isEmpty)
    }

    @Test func wrongChainMetadataIsDeniedBeforeConsentOrJournal() async throws {
        let parent = try ChainFixture.parent(me: P15.alice, attendees: [P15.alice, P15.bob])
        let waiting = try ChainFixture.waiting(parent: parent, me: P15.alice, cards: ChainFixture.cards([P15.bob]))
        let store = InMemoryInteractionStore([parent, waiting])
        let journal = InMemoryEgressJournal()
        let recorder = EgressRecorder(sink: StoreEgressSink(store: store), journal: journal, now: { P15.date })
        let transport = RecordingTransport(localPeer: P15.alice)
        let consent = ScriptedConsentProvider(.approved)
        let policy = ChainedFromPolicy(wrapping: DeterministicPolicyEngine(ownerRules: .empty), store: store)
        let outbox = Outbox(transport: transport, policy: policy, consent: consent, observer: recorder,
            ledger: InMemoryConversationLedger(), now: { P15.date })
        let body = MessageBody.propose(try Proposal(round: 0, terms: Terms([.photos: .count(2)])))
        for wrong: ConversationID? in [nil, ConversationID()] {
            await #expect(throws: OutboxError.denied(PolicyViolation(rule: ChainedFromPolicy.mismatchRule))) {
                try await outbox.send(body, to: P15.bob, conversation: waiting.conversation, skill: waiting.skill, mode: .invite, chainedFrom: wrong)
            }
        }
        #expect(await consent.requests.isEmpty)
        #expect(await transport.sent.isEmpty)
        #expect(try await journal.unresolved().isEmpty)
        _ = try await outbox.send(body, to: P15.bob, conversation: waiting.conversation, skill: waiting.skill, mode: .invite, chainedFrom: parent.conversation)
        #expect(try await store.interaction(waiting.id)?.egress.count == 1)
    }
}
