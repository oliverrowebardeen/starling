import Foundation
import StarlingChaining
import StarlingChangePlan
import StarlingCore
import StarlingFakes
import Testing

struct ChangePlanAttackTests {
    @Test func pc04AConfirmationForAnotherParentCannotCommitThisSuggestion() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1]
        let offer = try await a.send(.propose(world.proposal()), to: b, parent: world.origin)
        try await b.accept(offer.conversation)
        _ = try await b.wait(.confirmed, offer.conversation)
        let accepted = try await b.journal.records()
        let yes = try #require(accepted.first)
        guard case .accepted(let record) = yes else {
            Issue.record("A yes must be journaled before it is sent")
            await world.stop()
            return
        }
        #expect(accepted.count == 1)
        #expect(record.offer == offer.id && record.planConversation == world.origin && record.suggester == a.id)
        let before = try await b.plan(world.origin)
        let sentBeforeAttack = await b.sent()
        let confirmation = MessageBody.accept(Acceptance(proposal: offer.id, terms: try Terms([:])))
        _ = try await a.send(confirmation, to: b, conversation: offer.conversation, parent: ConversationID())
        // An accepted offer already exists. A confirmation for another
        // parent must not replace it with an applied receipt or change the plan.
        #expect(try await b.journal.records() == accepted)
        #expect(try await b.plan(world.origin) == before)
        #expect(try await b.events.interaction(offer.conversation)?.state == .confirmed)
        #expect(await b.sent() == sentBeforeAttack)
        _ = try await a.send(confirmation, to: b, conversation: offer.conversation, parent: world.origin)
        _ = try await b.wait(.planned, offer.conversation)
        try await P15.eventually("legitimate confirmation commits") { try await b.plan(world.origin).revision == 1 }
        #expect(try await b.journal.records().contains {
            if case .applied(let value) = $0 { value.offer == offer.id && value.planConversation == world.origin } else { false }
        })
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc05WrongOfferAndWrongPeerCannotSupplyAMissingVote() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2], x = world.phones[3]
        let change = try await world.start()
        let offer = try #require(await world.offers(change.conversation).first { $0.recipient == b.id })
        _ = try await b.send(.accept(Acceptance(proposal: MessageID(), terms: ChangeWorld.terms)), to: a,
            conversation: change.conversation, parent: world.origin)
        _ = try await x.send(.accept(Acceptance(proposal: offer.id, terms: ChangeWorld.terms)), to: a,
            conversation: change.conversation, parent: world.origin)
        try await c.accept(change.conversation)
        let cVote = try #require(await c.sent(change.conversation).last)
        try await world.received(cVote, by: 0)
        #expect(try await a.ledger.isRetired(change.conversation) == false)
        #expect(await a.sent(change.conversation).allSatisfy { $0.body.kind == .propose })
        try await b.accept(change.conversation)
        for phone in [a, b, c] { _ = try await phone.wait(.planned, change.conversation) }
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc06ALateConfirmationCannotOverwriteANewerLocalRevision() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1]
        let offer = try await a.send(.propose(world.proposal()), to: b, parent: world.origin)
        try await b.accept(offer.conversation)
        var root = try await b.root(world.origin)
        let newer = try #require(root.plan).updating(activity: .some(Keyword("coffee")))
        root.record(.plan(newer))
        try await b.events.store.save(root)
        _ = try await a.send(.accept(Acceptance(proposal: offer.id, terms: Terms([:]))), to: b,
            conversation: offer.conversation, parent: world.origin)
        // The stale confirmation is ignored; the original window still ends.
        world.clock.advance(to: P15.date.addingTimeInterval(300))
        _ = try await b.wait(.ended(.expired), offer.conversation)
        #expect(try await b.plan(world.origin) == newer)
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc11OnlyASuggesterFriendCanBeAddedAndNobodyCanBeRemoved() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2], n = world.phones[3]
        let cards = try [b.id: P15.card([ChangePlan.descriptor.ref]), c.id: P15.card([ChangePlan.descriptor.ref])]
        await #expect(throws: ChainError.cannotAdd) {
            _ = try await world.prepare(.change(time: nil, activity: nil, adding: n.id), cards: cards)
        }
        let removed = try Terms([.people: .peers([a.id, b.id, n.id])])
        let attack = try await a.send(.propose(Proposal(round: 0, terms: removed)), to: b, parent: world.origin)
        let control = try await a.send(.propose(world.proposal()), to: b, parent: world.origin)
        _ = try await b.wait(.proposed, control.conversation)
        #expect(try await b.events.interaction(attack.conversation) == nil)
        #expect(try await b.plan(world.origin).attendees.peers == [a.id, b.id, c.id])
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc15LeavingClosesTheOldSuggestionBeforeItsLateAcceptance() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2]
        let change = try await world.start()
        _ = try await b.wait(.proposed, change.conversation)
        _ = try await c.wait(.proposed, change.conversation)
        let offer = try #require(await world.offers(change.conversation).first { $0.recipient == b.id })
        _ = try await world.start(.leave, by: 1)
        try await P15.eventually("remaining roster recorded") { try await a.plan(world.origin).revision == 1 }
        // A malicious authenticated peer can discard its own ledger. The
        // receiving service must still enforce its retained retirement.
        let attacker = Outbox(transport: try #require(b.agent.secureTransport), policy: FixedPolicyEngine(.allow),
            consent: ScriptedConsentProvider(.approved), now: { world.clock.now.addingTimeInterval(1) })
        let late = try await attacker.send(.accept(Acceptance(proposal: offer.id, terms: ChangeWorld.terms)),
            to: a.id, conversation: change.conversation, skill: ChangePlan.descriptor.ref,
            mode: .invite, chainedFrom: world.origin)
        try await world.received(late, by: 0)
        #expect(try await a.plan(world.origin).activity == Keyword("boba"))
        #expect(try await a.plan(world.origin).attendees.peers == [a.id, c.id])
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc18WithdrawalAfterALostOfferMustNotBecomeLeavingThePlan() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2]
        await b.relay.drop(.propose)
        let change = try await world.start()
        let offer = try #require(await world.offers(change.conversation).first { $0.recipient == b.id })
        try await world.received(offer, by: 1)
        _ = try await c.wait(.proposed, change.conversation)
        await a.service.withdraw(change.id)
        let notice = try #require(await a.sent().first { $0.recipient == b.id && $0.body.kind == .reject && $0.chainedFrom == world.origin })
        #expect(notice.conversation != change.conversation)
        #expect(notice.body == .reject(Rejection(proposal: offer.id, reason: .declinedByOwner)))
        try await world.received(notice, by: 1)
        #expect(await b.sent(notice.conversation).first?.body == .accept(Acceptance(proposal: offer.id, terms: try Terms([:]))))
        _ = try await c.wait(.ended(.nobodyUp), change.conversation)
        // Finish and drain the event stream after the handled notice. This
        // observes every already-published update without a sleep.
        await b.stop()
        let unchanged = try await b.plan(world.origin)
        #expect(unchanged.attendees.peers == [a.id, b.id, c.id])
        #expect(unchanged.revision == 0)
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc25RestartRetiresAnOpenSuggestionAndRejectsLateReplies() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1]
        let change = try await world.start()
        let card = try await b.wait(.proposed, change.conversation)
        let offer = try #require(await world.offers(change.conversation).first { $0.recipient == b.id })
        try await b.restart()
        _ = try await b.wait(.ended(.failed), change.conversation)
        _ = try await a.send(.accept(Acceptance(proposal: offer.id, terms: Terms([:]))), to: b,
            conversation: change.conversation, parent: world.origin)
        #expect(try await b.ledger.isRetired(change.conversation))
        #expect(try await b.events.store.interaction(card.id)?.state == .ended(.failed))
        #expect(try await b.plan(world.origin).revision == 0)
        await world.checkHealthy()
        await world.stop()
    }
}
