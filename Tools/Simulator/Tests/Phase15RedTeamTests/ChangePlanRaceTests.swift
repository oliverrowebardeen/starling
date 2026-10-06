import Foundation
import StarlingChaining
import StarlingChangePlan
import StarlingCore
import StarlingFakes
import Testing

struct ChangePlanRaceTests {
    @Test func pc07CrossingSuggestionsSettleWithoutConflictingCommits() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2]
        let first = try await world.prepare()
        let second = try await world.prepare(.change(time: nil, activity: Keyword("coffee"), adding: nil), by: 1)
        await a.relay.drop(.propose)
        await b.relay.drop(.propose)
        try await world.launch(first)
        try await world.launch(second, by: 1)
        let toB = try #require(await a.sent(first.request.conversation).first { $0.recipient == b.id })
        let toA = try #require(await b.sent(second.request.conversation).first { $0.recipient == a.id })
        try await world.received(toB, by: 1)
        try await world.received(toA, by: 0)
        await a.relay.repeatDelivery(toA)
        await b.relay.repeatDelivery(toB)
        _ = try await c.wait(.proposed, first.request.conversation)
        try await c.accept(first.request.conversation)
        let vote = try #require(await c.sent(first.request.conversation).last)
        try await world.received(vote, by: 0)
        #expect(try await c.all().filter { $0.skill.id == .changePlan && !$0.state.isFinal }.count == 1)
        world.clock.advance(to: P15.date.addingTimeInterval(300))
        _ = try await a.wait(.ended(.nobodyUp), first.request.conversation)
        _ = try await b.wait(.ended(.nobodyUp), second.request.conversation)
        _ = try await c.wait(.ended(.expired), first.request.conversation)
        for phone in [a, b, c] { #expect(try await phone.plan(world.origin).revision == 0) }
        let control = try await world.start()
        _ = try await b.wait(.proposed, control.conversation)
        _ = try await c.wait(.proposed, control.conversation)
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc18WithdrawalCancelsARosterStillWaitingForConsent() async throws {
        let consent = DownConsent()
        let world = try await ChangeWorld.make(choices: [.people: .askMe, .place: .share], firstConsent: consent)
        let a = world.phones[0], b = world.phones[1], n = world.phones[3]
        await consent.hold(b.id)
        let start = try await world.prepare(.change(time: nil, activity: nil, adding: n.id))
        let sending = Task { try await world.launch(start) }
        try await P15.eventually("roster consent waiting") { await consent.requests.count == 1 }
        await a.service.withdraw(start.interaction.id)
        await consent.release()
        try await sending.value
        #expect(try await a.ledger.isRetired(start.request.conversation))
        #expect(await a.sent(start.request.conversation).isEmpty)
        #expect(try await a.plan(world.origin).revision == 0)
        await #expect(throws: OutboxError.conversationRetired) {
            try await a.send(.propose(Proposal(round: 0, terms: ChangeWorld.terms)), to: b,
                conversation: start.request.conversation, parent: world.origin)
        }
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc19FailedRetirementCannotPublishACleanDecline() async throws {
        let world = try await ChangeWorld.make()
        let b = world.phones[1]
        let change = try await world.start()
        let card = try await b.wait(.proposed, change.conversation)
        await b.ledger.gateRetirement(failing: true)
        let passing = Task { try await b.service.answer(card.id, with: .pass) }
        try await P15.eventually("change retirement suspended") { await b.ledger.retiring.contains(change.conversation) }
        #expect(try await b.events.interaction(change.conversation)?.state == .proposed)
        await b.ledger.release()
        try await passing.value
        _ = try await b.wait(.ended(.failed), change.conversation)
        #expect(await b.service.unretiredConversations.contains(change.conversation))
        #expect(await b.sent(change.conversation).isEmpty)
        #expect(try await b.plan(world.origin).revision == 0)
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc27AnEarlyAuthenticatedVoteSurvivesTheOfferSendStillInFlight() async throws {
        let gate = ChangeSendGate()
        let world = try await ChangeWorld.make(firstObserver: gate)
        let a = world.phones[0], b = world.phones[1], c = world.phones[2]
        let start = try await world.prepare()
        let sending = Task { try await world.launch(start) }
        try await P15.eventually("offer didSend held") { await gate.waiting }
        try await b.accept(start.request.conversation)
        let vote = try #require(await b.sent(start.request.conversation).last)
        try await world.received(vote, by: 0)
        #expect(await a.sent(start.request.conversation).count == 1)
        #expect(world.clock.now == P15.date)
        await gate.release()
        try await sending.value
        try await c.accept(start.request.conversation)
        for phone in [a, b, c] { _ = try await phone.wait(.planned, start.request.conversation) }
        #expect(world.clock.now == P15.date)
        await world.checkHealthy()
        await world.stop()
    }
}

extension ChangePlanRaceTests {
    @Test func pc19AChangeCannotCommitWithoutDurableConfirmationRecovery() async throws {
        let journal = ChangeFailingCommitJournal()
        let world = try await ChangeWorld.make(firstJournal: journal)
        let a = world.phones[0], b = world.phones[1], c = world.phones[2]
        await b.relay.dropConfirmations()
        let change = try await world.start()
        try await b.accept(change.conversation)
        try await c.accept(change.conversation)
        let lastVote = try #require(await c.sent(change.conversation).first { $0.body.kind == .accept })
        try await world.received(lastVote, by: 0)
        #expect(await journal.attempts > 0)
        await a.stop()
        let parent = try await a.plan(world.origin)
        let card = try #require(try await a.events.interaction(change.conversation))
        let sent = await a.sent(change.conversation)
        #expect(parent.revision == 0)
        #expect(card.state != .planned)
        #expect(sent.allSatisfy { $0.body.kind != .accept })
        await world.checkHealthy()
        await world.stop()
    }
}
