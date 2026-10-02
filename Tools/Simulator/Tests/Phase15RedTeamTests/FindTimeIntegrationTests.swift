import Foundation
import FindATime
import SimulatorKit
import StarlingAvailability
import StarlingAvailabilityFakes
import StarlingCore
import StarlingFakes
import Synchronization
import Testing

final class TimePhone: Sendable {
    let phone: PlacePhone
    let calendar: FakeCalendarStore
    let checkpoints = InMemoryFindATimeCheckpoints()
    let events = PlaceEvents(skill: FindATimeSkill.ref)
    let outbox: Outbox
    private let running = Mutex<FindATimeService?>(nil)
    private let tasks = Mutex<[Task<Void, Never>]>([])
    var service: FindATimeService { running.withLock { $0! } }
    init(_ phone: PlacePhone, calendar: FakeCalendarStore, outbox: Outbox? = nil) {
        self.phone = phone; self.calendar = calendar; self.outbox = outbox ?? phone.outbox
    }
    func boot(restore: Bool = false) async throws {
        let clock = phone.clock.clock
        let service = FindATimeService(localPeer: phone.id, outbox: outbox, conversations: phone.conversations, pairedPeers: phone.peers,
            availability: .standard(calendar: calendar, use: { .useMyCalendar }), checkpoints: checkpoints,
            clock: FindATimeClock(now: clock.now, sleep: clock.sleep), timeZone: TimeZone(secondsFromGMT: 0)!,
            configuration: FindATimeConfiguration(slotMinutes: 30, dailyFrom: 0, dailyTo: 1440,
                retryInterval: .seconds(5), answerWait: .seconds(20), confirmWait: .seconds(30)))
        running.withLock { $0 = service }
        let events = events
        tasks.withLock { $0.append(Task { for await event in service.events { await events.record(event) } }) }
        for hello in await phone.agent.received where hello.body.kind == .hello { await service.handle(.message(hello)) }
        if restore { await service.restore(try await events.store.all()) }
        await phone.relay.attach(service)
    }
    func restart() async throws {
        await phone.relay.attach(nil)
        await service.shutdown()
        try await boot(restore: true)
    }
    func stop() async { await service.shutdown(); for task in tasks.withLock({ $0 }) { task.cancel() } }
    func start(with peers: [PeerID], slots: [TimeSlot]) async throws -> Interaction {
        var interaction = Interaction(skill: FindATimeSkill.ref, role: .initiator, participants: peers, createdAt: P15.now)
        try interaction.apply(.started, at: P15.now)
        try await events.add(interaction)
        let rules = try OwnerRules(constraints: ConstraintSet([.time: [Constraint(.within(slots))]]))
        let intent = SkillIntent(skill: FindATimeSkill.ref, rules: rules, audience: .picked(peers), mode: .invite,
            expiresAt: Timestamp(P15.date.addingTimeInterval(600)))
        try await service.start(SkillRequest(interaction: interaction.id, conversation: interaction.conversation, intent: intent, participants: peers))
        return interaction
    }
    func wait(_ state: InteractionState, in conversation: ConversationID) async throws -> Interaction {
        try await Simulation.eventually("Find a time reaches \(state)") { (try? await self.events.interaction(conversation)?.state) == state }
        return try #require(await events.interaction(conversation))
    }
}

@Suite("P15-F real Find a time attacks", .serialized)
struct FindTimeIntegrationTests {
    static func slots(_ count: Int = 2) throws -> [TimeSlot] {
        try (0..<count).map { try TimeSlot(start: P15.date.addingTimeInterval(Double(60 + $0 * 60) * 60),
            end: P15.date.addingTimeInterval(Double(90 + $0 * 60) * 60)) }
    }
    func ask(_ slots: [TimeSlot], a: PlacePhone, b: PlacePhone, conversation: ConversationID) async throws -> Envelope {
        try await a.send(.query(Query(issue: .time, candidates: .slots(slots))), to: b.id, conversation: conversation, skill: FindATimeSkill.ref)
    }
    func propose(_ slot: TimeSlot, round: UInt16 = 0, a: PlacePhone, b: PlacePhone, conversation: ConversationID) async throws -> Envelope {
        try await a.send(.propose(Proposal(round: round, terms: Terms([.time: .slots([slot])]))), to: b.id,
            conversation: conversation, skill: FindATimeSkill.ref)
    }

    @Test func aDeniedCalendarStarterAndCalendarInviteeCompleteWithRealServices() async throws {
        let world = try await PlaceWorld.make(count: 2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        let starter = TimePhone(a, calendar: FakeCalendarStore(status: .denied))
        let invitee = TimePhone(b, calendar: FakeCalendarStore())
        try await starter.boot(); try await invitee.boot()
        defer { Task { await starter.stop(); await invitee.stop() } }
        for from in [a, b] {
            let other = from.id == a.id ? invitee : starter
            let hello = try await from.outbox.send(.hello(P15.card([FindATimeSkill.ref])), to: other.phone.id, conversation: ConversationID())
            try await Simulation.eventually("real time skill hello") { await other.phone.agent.received.contains(hello) }
            await other.service.handle(.message(hello))
        }
        let request = try await starter.start(with: [b.id], slots: Self.slots())
        let question = try await starter.wait(.awaitingOwner, in: request.conversation)
        let pending = try #require(question.pendingQuestion)
        try await starter.service.answer(question.id, with: .reply(question: pending.revision, pending.candidates))
        let aCard = try await starter.wait(.proposed, in: request.conversation)
        let bCard = try await invitee.wait(.proposed, in: request.conversation)
        try await starter.service.answer(aCard.id, with: .accept(proposal: #require(aCard.proposalRevision)))
        try await invitee.service.answer(bCard.id, with: .accept(proposal: #require(bCard.proposalRevision)))
        _ = try await starter.wait(.planned, in: request.conversation)
        _ = try await invitee.wait(.planned, in: request.conversation)
        #expect(starter.calendar.requestCount == 0 && invitee.calendar.requestCount == 0)
        #expect(starter.calendar.readCount == 0 && invitee.calendar.readCount > 0)
        #expect(await starter.events.invalid.isEmpty)
        #expect(await invitee.events.invalid.isEmpty)
    }

    @Test func aTimeAnswerMustNameAQueryTheOrganizerSent() async throws {
        let world = try await PlaceWorld.make(count: 2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        await b.relay.attach(nil)
        let starter = TimePhone(a, calendar: FakeCalendarStore())
        try await starter.boot()
        defer { Task { await starter.stop() } }
        let hello = try await b.outbox.send(.hello(P15.card([FindATimeSkill.ref])), to: a.id, conversation: ConversationID())
        try await Simulation.eventually("time capable card") { await a.agent.received.contains(hello) }
        await starter.service.handle(.message(hello))
        let request = try await starter.start(with: [b.id], slots: Self.slots())
        try await Simulation.eventually("time query delivered") { await b.agent.received.contains { $0.conversation == request.conversation && $0.body.kind == .query } }
        let envelope = try #require(await b.agent.received.first { $0.conversation == request.conversation && $0.body.kind == .query })
        guard case .query(let query) = envelope.body else { return }
        let invented = MessageID()
        let answer = try Answer(query: invented, issue: .time, status: .answered, acceptable: query.candidates)
        let attack = try await b.send(.answer(answer), to: a.id, conversation: request.conversation,
            context: OutboundContext(answering: query), skill: FindATimeSkill.ref)
        try await world.delivered(attack, to: a)
        let proposed = try await starter.events.interaction(request.conversation)?.proposal
        #expect(proposed == nil)
        let genuine = try Answer(query: envelope.id, issue: .time, status: .answered, acceptable: query.candidates)
        let accepted = try await b.send(.answer(genuine), to: a.id, conversation: request.conversation,
            context: OutboundContext(answering: query), skill: FindATimeSkill.ref)
        try await world.delivered(accepted, to: a)
        try await Simulation.eventually("genuine time answer advances the proposal") {
            (try? await starter.events.interaction(request.conversation)?.state) == .proposed
        }
    }

    @Test func sixteenTimeCandidatesSurviveLostInteractionsWithoutASeventeenthOracleAnswer() async throws {
        let world = try await PlaceWorld.make(count: 2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        await a.relay.attach(nil)
        let first = TimePhone(b, calendar: FakeCalendarStore())
        try await first.boot()
        defer { Task { await first.stop() } }
        let slots = try Self.slots(17), conversation = ConversationID()
        let sent = try await ask(Array(slots.prefix(16)), a: a, b: b, conversation: conversation)
        try await world.delivered(sent, to: b)
        try await Simulation.eventually("sixteen time answers reserved") { await b.conversations.base.answeredCount(issue: .time, to: a.id, in: conversation) == 16 }
        await first.stop()
        let replacement = TimePhone(b, calendar: FakeCalendarStore())
        try await replacement.boot()
        defer { Task { await replacement.stop() } }
        let before = await b.sent(conversation).count
        let overflow = try await ask([slots[16]], a: a, b: b, conversation: conversation)
        try await world.delivered(overflow, to: b)
        #expect(await b.sent(conversation).count == before)
        #expect(try await replacement.events.interaction(conversation) == nil)
        #expect(replacement.calendar.readCount == 0)
        let fresh = try await ask([slots[16]], a: a, b: b, conversation: ConversationID())
        try await world.delivered(fresh, to: b)
        try await Simulation.eventually("new time conversation is independent") { await b.sent(fresh.conversation).contains { $0.body.kind == .answer } }
    }

    @Test(arguments: [false, true])
    func anOwnerPassWaitsForTheRetirementWrite(fail: Bool) async throws {
        let world = try await PlaceWorld.make(count: 2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        await a.relay.attach(nil)
        let time = TimePhone(b, calendar: FakeCalendarStore(status: .denied))
        try await time.boot()
        defer { Task { await time.stop() } }
        let sent = try await ask(Self.slots(), a: a, b: b, conversation: ConversationID())
        try await world.delivered(sent, to: b)
        let question = try await time.wait(.awaitingOwner, in: sent.conversation)
        await b.conversations.gateRetirement(failing: fail)
        try await time.service.answer(question.id, with: .pass)
        try await Simulation.eventually("time retirement held") { await b.conversations.retiring.contains(sent.conversation) }
        #expect(try await time.events.interaction(sent.conversation)?.state == .awaitingOwner)
        await b.conversations.release()
        _ = try await time.wait(.ended(fail ? .failed : .declined), in: sent.conversation)
        #expect(await b.sent(sent.conversation).isEmpty)
    }

    @Test(arguments: [CalendarAccessStatus.denied, .restricted, .writeOnly, .notDetermined])
    func deniedCalendarUsesAnOwnerQuestionAndStillCompletes(status: CalendarAccessStatus) async throws {
        let world = try await PlaceWorld.make(count: 2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        await a.relay.attach(nil)
        let calendar = FakeCalendarStore(status: status, grantOnRequest: false)
        let time = TimePhone(b, calendar: calendar)
        try await time.boot()
        defer { Task { await time.stop() } }
        let slots = try Self.slots(), conversation = ConversationID()
        let sent = try await ask(slots, a: a, b: b, conversation: conversation)
        try await world.delivered(sent, to: b)
        let question = try await time.wait(.awaitingOwner, in: conversation)
        #expect(calendar.requestCount == 0 && calendar.readCount == 0)
        #expect(await b.sent(conversation).isEmpty)
        let revision = try #require(question.pendingQuestion?.revision)
        try await time.service.answer(question.id, with: .reply(question: revision, .slots([slots[0]])))
        try await Simulation.eventually("owner's bounded answer sent") { await b.sent(conversation).contains { $0.body.kind == .answer } }
        let proposal = try await propose(slots[0], a: a, b: b, conversation: conversation)
        try await world.delivered(proposal, to: b)
        let card = try await time.wait(.proposed, in: conversation)
        try await time.service.answer(card.id, with: .accept(proposal: #require(card.proposalRevision)))
        try await Simulation.eventually("time acceptance left") { await b.sent(conversation).contains { $0.body.kind == .accept } }
        guard case .propose(let offer) = proposal.body else { return }
        let confirmation = try await a.send(.accept(Acceptance(proposal: proposal.id, terms: offer.terms)), to: b.id,
            conversation: conversation, skill: FindATimeSkill.ref)
        try await world.delivered(confirmation, to: b)
        _ = try await time.wait(.planned, in: conversation)
        #expect(calendar.requestCount == 0 && calendar.readCount == 0)
        #expect(await time.events.invalid.isEmpty)
    }

    @Test func calendarMarkersStayOutOfWireCheckpointsAndModelFacts() async throws {
        let world = try await PlaceWorld.make(count: 2, neverOnInvitee: true)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        await a.relay.attach(nil)
        let slots = try Self.slots()
        let event = FakeCalendarEvent(title: "SECRET_CALENDAR_TITLE", location: "SECRET_COORDINATE", notes: "SECRET_NOTE",
            attendees: ["SECRET_ATTENDEE"], start: slots[0].start, end: slots[0].end)
        let calendar = FakeCalendarStore(events: [event])
        let time = TimePhone(b, calendar: calendar)
        try await time.boot()
        defer { Task { await time.stop() } }
        let conversation = ConversationID()
        let sent = try await ask(slots, a: a, b: b, conversation: conversation)
        try await world.delivered(sent, to: b)
        try await Simulation.eventually("calendar subset answer") { await b.sent(conversation).contains { $0.body.kind == .answer } }
        let answer = try #require(await b.sent(conversation).first)
        guard case .answer(let value) = answer.body else { Issue.record("Expected answer"); return }
        #expect(value.query == sent.id && value.acceptable == .slots([slots[1]]))
        let proposal = try await propose(slots[1], a: a, b: b, conversation: conversation)
        try await world.delivered(proposal, to: b)
        let card = try await time.wait(.proposed, in: conversation)
        let facts = Mutex<[ProposalFacts]>([])
        let writer = FindATimeProposalWriter(model: ScriptedSkillModel(onProposal: { input in facts.withLock { $0.append(input) }; return "Boba with Sam" }),
            localPeer: b.id, timeZone: TimeZone(secondsFromGMT: 0)!, nickname: { _ in "Sam" })
        _ = await writer.sentence(for: try #require(card.proposal))
        await time.service.shutdown() // Flushes the real checkpoint writer.
        let payloads = try await b.sent(conversation).map { String(decoding: try EnvelopeCodec().encode($0), as: UTF8.self) }
            + time.checkpoints.all().map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        let surfaces = payloads + [String(describing: await b.consent.requests), String(describing: await time.events.received), facts.withLock { String(describing: $0) }]
        for marker in event.details { #expect(surfaces.allSatisfy { !$0.contains(marker) }) }
        #expect(calendar.readCount > 0 && calendar.requestCount == 0)
        #expect(await b.consent.requests.isEmpty)
    }

    @Test func staleProposalWrongModeAndWrongMajorCannotReplaceTheCurrentCard() async throws {
        let world = try await PlaceWorld.make(count: 2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        await a.relay.attach(nil)
        let time = TimePhone(b, calendar: FakeCalendarStore())
        try await time.boot()
        defer { Task { await time.stop() } }
        let slots = try Self.slots(), conversation = ConversationID()
        let sent = try await ask(slots, a: a, b: b, conversation: conversation)
        try await world.delivered(sent, to: b)
        let newest = try await propose(slots[1], round: 1, a: a, b: b, conversation: conversation)
        try await world.delivered(newest, to: b)
        let current = try await time.wait(.proposed, in: conversation)
        for (round, mode, version) in [(UInt16(0), SendMode.invite, SkillVersion(1)), (2, .askQuietly, SkillVersion(1)), (2, .invite, SkillVersion(2))] {
            let bad = try await a.send(.propose(Proposal(round: round, terms: Terms([.time: .slots([slots[0]])]))), to: b.id,
                conversation: conversation, skill: SkillRef(.findATime, version), mode: mode)
            try await world.delivered(bad, to: b)
        }
        #expect(try await time.events.interaction(conversation)?.proposal == current.proposal)
        try await time.restart()
        #expect(try await time.events.interaction(conversation)?.proposal == current.proposal)
        try await time.service.answer(current.id, with: .pass)
        _ = try await time.wait(.ended(.declined), in: conversation)
        #expect(try await b.conversations.isRetired(conversation))
        let before = await b.sent(conversation).count
        try await time.restart()
        let replay = try await ask(slots, a: a, b: b, conversation: conversation)
        try await world.delivered(replay, to: b)
        #expect(await b.sent(conversation).count == before)
        #expect(try await time.events.interaction(conversation)?.state == .ended(.declined))
    }

    @Test(arguments: [false, true])
    func aCurrentDeniedAcceptanceEndsButAnOldDenialCannotEndANewerProposal(superseded: Bool) async throws {
        let world = try await PlaceWorld.make(count: 2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        await a.relay.attach(nil)
        let policy = SuspendedTimeDenial(base: b.policy)
        let outbox = Outbox(transport: try #require(b.agent.secureTransport), policy: policy, consent: b.consent,
            observer: b.observer, ledger: b.conversations, now: { P15.date })
        let time = TimePhone(b, calendar: FakeCalendarStore(), outbox: outbox)
        try await time.boot()
        defer { Task { await policy.release(); await time.stop() } }
        let slots = try Self.slots(), conversation = ConversationID()
        let sent = try await ask(slots, a: a, b: b, conversation: conversation)
        try await world.delivered(sent, to: b)
        let first = try await propose(slots[0], a: a, b: b, conversation: conversation)
        try await world.delivered(first, to: b)
        let card = try await time.wait(.proposed, in: conversation)
        try await time.service.answer(card.id, with: .accept(proposal: #require(card.proposalRevision)))
        try await Simulation.eventually("old acceptance policy suspended") { await policy.waiting }
        if superseded {
            let next = try await propose(slots[1], round: 1, a: a, b: b, conversation: conversation)
            try await world.delivered(next, to: b)
            _ = try await time.wait(.proposed, in: conversation)
        }
        await policy.release()
        if superseded {
            try await Task.sleep(for: .milliseconds(100))
            #expect(try await time.events.interaction(conversation)?.proposal?.terms[.time] == .slots([slots[1]]))
            #expect(try await time.events.interaction(conversation)?.state == .proposed)
            #expect(try await !b.conversations.isRetired(conversation))
        } else {
            _ = try await time.wait(.ended(.blockedByPrivacy), in: conversation)
            #expect(try await b.conversations.isRetired(conversation))
        }
        #expect(await b.sent(conversation).allSatisfy { $0.body.kind == .answer })
    }
}

private actor SuspendedTimeDenial: PolicyEngine {
    let base: any PolicyEngine
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    init(base: any PolicyEngine) { self.base = base }
    func release() { continuation?.resume(); continuation = nil }
    func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        if message.envelope.body.kind == .accept {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
            return .deny(PolicyViolation(rule: "test.current-acceptance", issue: .time))
        }
        return await base.evaluate(message)
    }
    func disclosedItems(for message: OutboundMessage) async throws -> [DisclosedItem] { try await base.disclosedItems(for: message) }
}
