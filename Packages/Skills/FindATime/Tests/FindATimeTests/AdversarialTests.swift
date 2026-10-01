@testable import FindATime
import Foundation
import StarlingAvailability
import StarlingAvailabilityFakes
import StarlingCore
import StarlingFakes
import Testing

/// Every peer value is untrusted. A friend's modified app ("Mallory") sends
/// crafted messages through its own Outbox; none may create a card, a
/// question, or a send it should not, and none may raise a permission alert.
@Suite(.serialized)
struct AdversarialTests {
    func query(_ slots: [TimeSlot]) throws -> MessageBody { .query(try Query(issue: .time, candidates: .slots(slots))) }

    /// Waits for messages to be handled, then returns the target's cards.
    func settle(_ phone: Phone) async throws -> [Interaction] {
        try await Task.sleep(for: .milliseconds(60))
        return await phone.coordinator.all()
    }

    @Test func outOfBoundsQueriesCreateNothing() async throws {
        let world = World()
        let mallory = world.phone("Mallory")
        let calendar = FakeCalendarStore(status: .notDetermined)
        let target = world.phone("Ben", calendar: calendar)
        try await world.start()

        let tooMany = (0..<17).map { T.slot(9 + Double($0) * 0.5, 9.5 + Double($0) * 0.5) }
        try await mallory.send(query(tooMany), to: target, conversation: ConversationID())
        try await mallory.send(query([T.slot(-48, -47)]), to: target, conversation: ConversationID())
        try await mallory.send(query([T.slot(24 * 20, 24 * 20 + 1)]), to: target, conversation: ConversationID())
        try await mallory.send(query([T.slot(9, 20)]), to: target, conversation: ConversationID())
        try await mallory.send(.query(Query(issue: .budget, candidates: .slots([T.slot(9, 10)]))), to: target, conversation: ConversationID())
        try await mallory.send(.query(Query(issue: .time, candidates: .keywords([Keyword("now")]))), to: target, conversation: ConversationID())
        try await mallory.send(query([T.slot(9, 10)]), to: target, conversation: ConversationID(), skill: SkillRef(.findATime, SkillVersion(2)))
        try await mallory.send(query([T.slot(9, 10)]), to: target, conversation: ConversationID(), skill: nil)

        #expect(try await settle(target).isEmpty)
        #expect(calendar.requestCount == 0)
        #expect(world.envelopes.allSatisfy { $0.sender == mallory.id || $0.skill == nil })
        await world.stop()
    }

    @Test func strangersAreIgnored() async throws {
        let world = World()
        let stranger = world.phone("Stranger")
        let target = world.phone("Ben", calendar: FakeCalendarStore(status: .denied))
        try await world.start(pairAll: false)
        try await stranger.pair(with: target)
        try await stranger.send(query([T.slot(9, 10)]), to: target, conversation: ConversationID())
        #expect(try await settle(target).isEmpty)
        await world.stop()
    }

    @Test func oneFriendCannotFloodNeedsYou() async throws {
        let world = World()
        let mallory = world.phone("Mallory")
        let target = world.phone("Ben", calendar: FakeCalendarStore(status: .denied))
        try await world.start()
        for _ in 0..<6 { try await mallory.send(query([T.slot(9, 10)]), to: target, conversation: ConversationID()) }
        let cards = try await settle(target)
        #expect(cards.count == FindATimeConfiguration().maxOpenInvitationsPerFriend)
        await world.stop()
    }

    /// ADR 0012: `chainedFrom` is a hint. The request still arrives as one
    /// invitee interaction under Needs you, with no permission asked.
    @Test func aChainHintStartsNothing() async throws {
        let world = World()
        let mallory = world.phone("Mallory")
        let calendar = FakeCalendarStore(status: .notDetermined)
        let target = world.phone("Ben", calendar: calendar)
        try await world.start()
        let parent = ConversationID()
        try await mallory.send(query([T.slot(9, 10)]), to: target, conversation: ConversationID(), chainedFrom: parent)
        _ = try await target.waitForQuestion()
        let cards = await target.coordinator.all()
        #expect(cards.count == 1)
        #expect(cards.allSatisfy { $0.role == .invitee })
        #expect(await target.coordinator.log.contains { if case .incoming(_, _, _, parent?) = $0 { true } else { false } })
        #expect(calendar.requestCount == 0)
        await world.stop()
    }

    /// A proposal for a time the owner never said works, or from someone
    /// other than the asker, never becomes a card.
    @Test func proposalsOutsideTheAnswerOrFromOthersAreIgnored() async throws {
        let world = World()
        let mallory = world.phone("Mallory")
        let eve = world.phone("Eve")
        let target = world.phone("Ben")
        try await world.start()
        let conversation = ConversationID()
        try await mallory.send(query([T.slot(9, 10), T.slot(10, 11)]), to: target, conversation: conversation)
        try await eventually("Ben answered") { world.envelopes.contains { $0.sender == target.id && $0.body.kind == .answer } }

        let outside = try Terms([.time: .slots([T.slot(15, 16)])])
        try await mallory.send(.propose(Proposal(round: 0, terms: outside)), to: target, conversation: conversation)
        let inside = try Terms([.time: .slots([T.slot(9, 10)])])
        try await eve.send(.propose(Proposal(round: 0, terms: inside)), to: target, conversation: conversation)
        let extra = try Terms([.time: .slots([T.slot(9, 10)]), .budget: .amount(MoneyAmount(minorUnits: 100))])
        try await mallory.send(.propose(Proposal(round: 0, terms: extra)), to: target, conversation: conversation)
        let twoTimes = try Terms([.time: .slots([T.slot(9, 10), T.slot(10, 11)])])
        try await mallory.send(.propose(Proposal(round: 0, terms: twoTimes)), to: target, conversation: conversation)
        let foreignRoster = try Terms([.time: .slots([T.slot(9, 10)]), .people: .peers([mallory.id, eve.id, PeerID.random()])])
        try await mallory.send(.propose(Proposal(round: 0, terms: foreignRoster)), to: target, conversation: conversation)
        #expect(try await settle(target).allSatisfy { $0.proposal == nil })

        // The real one still works.
        try await mallory.send(.propose(Proposal(round: 0, terms: inside)), to: target, conversation: conversation)
        _ = try await target.waitForProposal()
        await world.stop()
    }

    /// A confirmation for terms the owner never accepted makes no plan.
    @Test func aForgedConfirmationMakesNoPlan() async throws {
        let world = World()
        let mallory = world.phone("Mallory")
        let target = world.phone("Ben")
        try await world.start()
        let conversation = ConversationID()
        try await mallory.send(query([T.slot(9, 10), T.slot(10, 11)]), to: target, conversation: conversation)
        try await eventually("Ben answered") { world.envelopes.contains { $0.sender == target.id && $0.body.kind == .answer } }
        let terms = try Terms([.time: .slots([T.slot(9, 10)])])
        let offer = try await mallory.send(.propose(Proposal(round: 0, terms: terms)), to: target, conversation: conversation)
        let (card, _) = try await target.waitForProposal()
        // Confirmed before the owner said anything.
        try await mallory.send(.accept(Acceptance(proposal: offer.id, terms: terms)), to: target, conversation: conversation)
        #expect(try await settle(target).allSatisfy { $0.state == .proposed })

        try await target.accept(card)
        let other = try Terms([.time: .slots([T.slot(10, 11)])])
        try await mallory.send(.accept(Acceptance(proposal: offer.id, terms: other)), to: target, conversation: conversation)
        try await mallory.send(.accept(Acceptance(proposal: MessageID(), terms: terms)), to: target, conversation: conversation)
        #expect(try await settle(target).allSatisfy { $0.state == .confirmed && $0.plan == nil })
        await world.stop()
    }

    /// A late or replayed query after a pass gets "no plan" again, never a
    /// new question.
    @Test func aRetriedQueryNeverReopensAPass() async throws {
        let world = World()
        let mallory = world.phone("Mallory")
        let target = world.phone("Ben", calendar: FakeCalendarStore(status: .denied))
        try await world.start()
        let conversation = ConversationID()
        try await mallory.send(query([T.slot(9, 10)]), to: target, conversation: conversation)
        let (asked, _) = try await target.waitForQuestion()
        try await target.service.answer(asked, with: .pass)
        try await target.waitForState(asked, .ended(.declined))
        for _ in 0..<3 { try await mallory.send(query([T.slot(9, 10)]), to: target, conversation: conversation) }
        let cards = try await settle(target)
        #expect(cards.count == 1)
        #expect(cards.first?.state == .ended(.declined))
        await world.stop()
    }

    /// The starter takes only answers from friends it asked, and only times
    /// it offered: a friend cannot steer the plan to a time never offered.
    @Test func answersOutsideTheOfferAreIgnored() async throws {
        let world = World()
        let a = world.phone("Ana", use: .justAskMe)
        let b = world.phone("Ben")
        let mallory = world.phone("Mallory")
        try await world.start()
        await b.transport.lose(100) { $0.body.kind == .answer }

        let started = try await a.findATime(with: [b])
        let (_, own) = try await a.waitForQuestion(started)
        try await a.reply(started, question: own.revision, [T.slot(18, 19)])
        try await eventually("Ana's query") { world.envelopes.contains { $0.sender == a.id && $0.body.kind == .query } }
        let conversation = world.envelopes.first { $0.sender == a.id && $0.body.kind == .query }!.conversation
        let queryID = world.envelopes.first { $0.sender == a.id && $0.body.kind == .query }!.id

        let steer = try Answer(query: queryID, issue: .time, status: .answered, acceptable: .slots([T.slot(3, 4)]))
        // Mallory was never asked; Ben's real phone is silenced, so a forged
        // answer under Ben's name would have to come through Ben's key.
        try await mallory.send(.answer(steer), to: a, conversation: conversation)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await a.coordinator.interaction(started)?.state == .negotiating)
        #expect(await a.service.diagnostics.ignored["answer out of turn", default: 0] >= 1)

        // The same answer as if from Ben (Loopback cannot authenticate; the
        // secure channel would drop this, so the check here is the last line).
        let forged = try Envelope(
            conversation: conversation, sender: b.id, recipient: a.id, sequence: 9_000, sentAt: Timestamp(Date()),
            body: .answer(steer), skill: FindATimeSkill.ref
        )
        try await world.hub.inject(Frame(EnvelopeCodec().encode(forged)), claimedSender: b.id, to: a.id)
        try await eventually("forged answer refused") { await a.service.diagnostics.ignored["answer outside the offer", default: 0] == 1 }
        #expect(await a.coordinator.interaction(started)?.state == .negotiating)
        await world.stop()
    }
}
