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
        // A quiet ask is a mode Find a time does not offer: never a card (ADR 0020).
        try await mallory.send(query([T.slot(9, 10)]), to: target, conversation: ConversationID(), mode: .askQuietly)

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

    /// Review of PR #53, finding 3: a confirmation that arrives while our
    /// acceptance is still on its consent sheet makes no plan. It is held,
    /// and counts only once the acceptance has actually left.
    @Test func aConfirmationBeforeOurAcceptanceLeftWaitsForIt() async throws {
        let world = World()
        let mallory = world.phone("Mallory")
        let sheet = HeldConsent()
        let target = world.phone("Ben", policy: FixedPolicyEngine(decide: { message in
            guard case .accept = message.envelope.body else { return .allow }
            return .needsConsent(Disclosure(recipient: message.envelope.recipient, recipientModel: nil, items: [],
                                            conversation: message.envelope.conversation, skill: message.envelope.skill, interaction: message.context.interaction))
        }), consent: sheet)
        try await world.start()
        let conversation = ConversationID()
        try await mallory.send(query([T.slot(9, 10), T.slot(10, 11)]), to: target, conversation: conversation)
        try await eventually("Ben answered") { world.envelopes.contains { $0.sender == target.id && $0.body.kind == .answer } }
        let terms = try Terms([.time: .slots([T.slot(9, 10)])])
        let offer = try await mallory.send(.propose(Proposal(round: 0, terms: terms)), to: target, conversation: conversation)
        let (card, _) = try await target.waitForProposal()
        try await target.accept(card)
        try await eventually("Ben's sheet is open") { await sheet.asked == 1 }

        try await mallory.send(.accept(Acceptance(proposal: offer.id, terms: terms)), to: target, conversation: conversation)
        #expect(try await settle(target).allSatisfy { $0.plan == nil })

        await sheet.answerAll(.approved)
        try await target.waitForState(card, .planned)
        #expect(world.envelopes.contains { $0.sender == target.id && $0.body.kind == .accept })
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
        // Nor any reply: how many there are would tell how it ended.
        #expect(!world.envelopes.contains { $0.sender == target.id && $0.skill != nil })
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
        // Mallory's own Outbox wants the query an answer replies to (ADR 0021).
        try await mallory.send(.answer(steer), to: a, conversation: conversation,
                               answering: try Query(issue: .time, candidates: .slots([T.slot(3, 4)])))
        try await eventually("Mallory's answer refused") { await a.service.diagnostics.ignored["answer out of turn", default: 0] >= 1 }
        #expect(await a.coordinator.interaction(started)?.state == .negotiating)

        // The same answer as if from Ben (Loopback cannot authenticate; the
        // secure channel would drop this, so the check here is the last line).
        let forged = try Envelope(
            conversation: conversation, sender: b.id, recipient: a.id, sequence: 9_000, sentAt: Timestamp(Date()),
            body: .answer(steer), skill: FindATimeSkill.ref, mode: .invite
        )
        try await world.hub.inject(Frame(EnvelopeCodec().encode(forged)), claimedSender: b.id, to: a.id)
        try await eventually("forged answer refused") { await a.service.diagnostics.ignored["answer outside the offer", default: 0] == 1 }
        #expect(await a.coordinator.interaction(started)?.state == .negotiating)
        await world.stop()
    }

    /// Reviews of PR #53 (second and final rounds) and ADR 0021: an ended
    /// conversation is retired for good in the conversation ledger, so its
    /// ID can never be reused for more answers, however many other
    /// conversations push it out of memory, and after a restart.
    @Test func anEndedConversationStaysClosedAfterForgettingAndRestarts() async throws {
        let world = World()
        let mallory = world.phone("Mallory")
        // Free on day 0, busy all of day 2 (where the filler requests go).
        let target = world.phone("Ben", calendar: FakeCalendarStore(events: [FakeCalendarEvent(title: "Away", start: T.at(48), end: T.at(72))]))
        try await world.start()

        let conversation = ConversationID()
        let first = (0..<16).map { T.slot(9 + Double($0) * 0.5, 9.5 + Double($0) * 0.5) }
        try await mallory.send(query(first), to: target, conversation: conversation)
        try await eventually("Ben answered about 16 times") { world.envelopes.contains { $0.sender == target.id && $0.body.kind == .answer } }
        try await mallory.send(.reject(Rejection(proposal: MessageID(), reason: .noOverlap)), to: target, conversation: conversation)
        try await eventually("conversation retired") { (try? await target.conversations.isRetired(conversation)) == true }

        // Push the ended conversation out of the service's memory.
        for i in 0...FindATimeService.maxTombstones {
            try await mallory.send(query([T.slot(48 + Double(i % 20) * 0.5, 48.5 + Double(i % 20) * 0.5)]), to: target, conversation: ConversationID())
            try await eventually("filler \(i) ended") { await target.service.invited.isEmpty }
        }
        #expect(await target.service.finished[conversation] == nil)

        // A fresh query in the same conversation, about 16 new times.
        let second = (0..<16).map { T.slot(24 + 9 + Double($0) * 0.5, 24 + 9.5 + Double($0) * 0.5) }
        let answersBefore = world.envelopes.filter { $0.sender == target.id && $0.body.kind == .answer }.count
        try await mallory.send(query(second), to: target, conversation: conversation)
        try await eventually("refused") { await target.service.diagnostics.ignored["retired conversation", default: 0] == 1 }

        // And again after a relaunch, with only the ledger to go on.
        await target.restart()
        try await target.greetAgain(world)
        try await mallory.send(query(second), to: target, conversation: conversation)
        try await eventually("refused after a restart") { await target.service.diagnostics.ignored["retired conversation", default: 0] == 1 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(world.envelopes.filter { $0.sender == target.id && $0.body.kind == .answer }.count == answersBefore)
        #expect(await target.coordinator.all().filter { $0.conversation == conversation }.count == 1)
        await world.stop()
    }

    /// ADR 0021: a conversation whose 16 candidates are already reserved for
    /// this friend gets no card for new times, and no answer leaves.
    @Test func aSpentConversationOpensNothing() async throws {
        let world = World()
        let mallory = world.phone("Mallory")
        let target = world.phone("Ben")
        try await world.start()
        let conversation = ConversationID()
        let earlier = (0..<16).map { IssueValue.slots([T.slot(9 + Double($0) * 0.5, 9.5 + Double($0) * 0.5)]) }
        #expect(try await target.conversations.reserve(earlier, issue: .time, to: mallory.id, in: conversation))

        try await mallory.send(query([T.slot(30, 31)]), to: target, conversation: conversation)
        try await eventually("refused") { await target.service.diagnostics.ignored["answer budget spent", default: 0] == 1 }
        #expect(await target.coordinator.all().isEmpty)
        #expect(!world.envelopes.contains { $0.sender == target.id && $0.skill != nil })
        await world.stop()
    }

    /// ADR 0021: a ledger that cannot be read refuses; nothing opens and
    /// nothing is sent, rather than answering as if it were empty.
    @Test func aFailingLedgerRefuses() async throws {
        let world = World()
        let mallory = world.phone("Mallory")
        let target = world.phone("Ben")
        try await world.start()
        await target.conversations.failAll()
        try await mallory.send(query([T.slot(9, 10)]), to: target, conversation: ConversationID())
        try await eventually("refused") { await target.service.diagnostics.ignored["ledger unavailable", default: 0] == 1 }
        #expect(await target.coordinator.all().isEmpty)
        #expect(!world.envelopes.contains { $0.sender == target.id && $0.skill != nil })
        await world.stop()
    }
}
