import Foundation
import StarlingChaining
import StarlingChangePlan
import StarlingCore
import StarlingFakes
import Testing

/// Change the plan across three or four phones, with every frame passing
/// through Outbox, the transport, and the receiver's Inbox (ADR 0022).
@Suite struct TranscriptTests {
    let alex = Fixtures.alex, maya = Fixtures.maya, jake = Fixtures.jake, sam = Fixtures.sam

    static func cardsUp(_ group: Group, _ people: [PeerID]) async -> Bool {
        for person in people where await group.openCard(of: person) == nil { return false }
        return true
    }

    @Test func everyoneSaysYesAndTheTimeChangesOnEveryPhone() async throws {
        let group = Group()
        let network = group.network
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("both cards up") { await Self.cardsUp(group, [maya, jake]) }
        // The card shows the plan as it would be.
        let card = try await group.card(of: maya)
        #expect(card.proposal?.plan?.time == Fixtures.later)
        #expect(card.proposal?.plan?.revision == 1)
        #expect(card.friendChainHint == group.origin)

        for person in [maya, jake] {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        await network.deliver()
        try await network.until("applied everywhere") {
            for person in [alex, maya, jake] where await group.phone(person).plan(group.origin)?.revision != 1 { return false }
            return true
        }
        for person in [alex, maya, jake] {
            let plan = try #require(await group.phone(person).plan(group.origin))
            #expect(plan.time == Fixtures.later)
            #expect(plan.activity == Fixtures.boba)
            #expect(plan.attendees.peers == [alex, maya, jake])
        }
        #expect(await group.phone(alex).interaction(link.id)?.state == .planned)
        #expect(network.transcript == [
            "Alex > Maya: propose", "Alex > Jake: propose",
            "Maya > Alex: accept", "Jake > Alex: accept",
            "Alex > Maya: accept", "Alex > Jake: accept",
            // Each acknowledges the confirmation once applied.
            "Maya > Alex: accept", "Jake > Alex: accept",
        ])
        // On Alex's phone the change is on the plan's timeline.
        let timeline = try #require(PlanTimeline(for: group.roots[alex]!.id, in: await group.phone(alex).all(), registry: Fixtures.registry))
        #expect(timeline.entries.map(\.origin) == [.plan, .chained(.whilePlanned, optedInAt: link.chain!.optedInAt)])
        // On Maya's, as a friend's request grouped under the plan.
        let theirs = try #require(PlanTimeline(for: group.roots[maya]!.id, in: await group.phone(maya).all(), registry: Fixtures.registry))
        #expect(theirs.entries.map(\.origin) == [.plan, .friend])
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aDeclineLooksLikeSilenceAndThePlanStaysAsItWas() async throws {
        let group = Group()
        let network = group.network
        let link = try await group.suggest(.change(time: nil, activity: Fixtures.dinner, adding: nil), by: alex, expiresIn: 30)
        await network.deliver()
        try await network.until("both cards up") { await Self.cardsUp(group, [maya, jake]) }
        try await group.phone(maya).service.answer(try await group.card(of: maya).id, with: .accept(proposal: 1))
        let jakesCard = try await group.card(of: jake)
        try await group.phone(jake).service.answer(jakesCard.id, with: .pass)
        await network.deliver()
        // Jake's pass sent nothing.
        #expect(network.transcript == ["Alex > Maya: propose", "Alex > Jake: propose", "Maya > Alex: accept"])

        // The window closes.
        group.clock.advance(to: Fixtures.date(minutes: 41))
        try await network.until("everything settled") {
            await group.phone(alex).interaction(link.id)?.state.isFinal == true
        }
        try await network.until("Maya's card closed") {
            await group.phone(maya).changes().allSatisfy(\.state.isFinal)
        }
        // Alex sees only that it stays as it was: no names, nobody up.
        #expect(await group.phone(alex).interaction(link.id)?.state == .ended(.nobodyUp))
        #expect(await group.phone(jake).interaction(jakesCard.id)?.state == .ended(.declined))
        #expect(await group.phone(maya).changes().first?.state == .ended(.expired))
        for person in [alex, maya, jake] {
            let plan = try #require(await group.phone(person).plan(group.origin))
            #expect(plan.activity == Fixtures.boba)
            #expect(plan.revision == 0)
        }
        // The conversation is retired everywhere.
        for person in [alex, maya, jake] { #expect(try await group.phone(person).ledger.isRetired(link.conversation)) }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func theSuggesterCanWithdrawAndEveryCardCloses() async throws {
        let group = Group()
        let network = group.network
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("cards up") { await Self.cardsUp(group, [maya, jake]) }
        try await group.phone(maya).service.answer(try await group.card(of: maya).id, with: .accept(proposal: 1))
        await network.deliver()
        // Alex withdraws (the coordinator records it), the cards close.
        var withdrawn = try #require(await group.phone(alex).interaction(link.id))
        try withdrawn.apply(.withdrawn, at: Timestamp(group.clock.now))
        try await group.phone(alex).store.save(withdrawn)
        await group.phone(alex).service.withdraw(link.id)
        await network.deliver()
        try await network.until("cards closed") {
            let mayas = await group.phone(maya).changes()
            let jakes = await group.phone(jake).changes()
            return mayas.allSatisfy(\.state.isFinal) && jakes.allSatisfy(\.state.isFinal)
        }
        #expect(await group.phone(jake).changes().first?.state == .ended(.nobodyUp))
        for person in [alex, maya, jake] { #expect(await group.phone(person).plan(group.origin)?.revision == 0) }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func addingAFriendNeedsEveryoneThenTheFriend() async throws {
        let group = Group(extra: [Fixtures.sam])
        let network = group.network
        try await group.suggest(.change(time: nil, activity: nil, adding: sam), by: alex)
        await network.deliver()
        try await network.until("cards up") { await Self.cardsUp(group, [maya, jake]) }
        // Nothing reaches Sam before everyone agrees.
        #expect(!network.transcript.contains { $0.contains("> Sam") })
        for person in [maya, jake] {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        await network.deliver()
        try await network.until("Sam's card up") { await Self.cardsUp(group, [sam]) }
        let samsCard = try await group.card(of: sam)
        // Sam sees the plan as it will be, with its people.
        #expect(samsCard.proposal?.plan?.attendees.peers == [alex, maya, jake, sam])
        #expect(samsCard.proposal?.plan?.activity == Fixtures.boba)
        #expect(samsCard.friendChainHint == nil)
        try await group.phone(sam).service.answer(samsCard.id, with: .accept(proposal: 1))
        await network.deliver()
        try await network.until("roster updated") {
            for person in [alex, maya, jake, sam] where await group.phone(person).plan(group.origin)?.attendees.peers.count != 4 { return false }
            return true
        }
        // Sam now holds the plan, named by its origin like everyone else's.
        let samsPlan = try #require(await group.phone(sam).plan(group.origin))
        #expect(samsPlan.revision == 1)
        #expect(samsPlan.time == Fixtures.tonight)
        #expect(network.transcript == [
            "Alex > Maya: propose", "Alex > Jake: propose",
            "Maya > Alex: accept", "Jake > Alex: accept",
            "Alex > Sam: propose", "Sam > Alex: accept",
            "Alex > Maya: accept", "Alex > Jake: accept", "Alex > Sam: accept",
            "Maya > Alex: accept", "Jake > Alex: accept", "Sam > Alex: accept",
        ])
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aFriendWhoDoesNotJoinLeavesThePlanAsItWas() async throws {
        let group = Group(extra: [Fixtures.sam])
        let network = group.network
        let link = try await group.suggest(.change(time: nil, activity: nil, adding: sam), by: alex, expiresIn: 30)
        await network.deliver()
        try await network.until("cards up") { await Self.cardsUp(group, [maya, jake]) }
        for person in [maya, jake] {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        await network.deliver()
        try await network.until("Sam's card up") { await Self.cardsUp(group, [sam]) }
        group.clock.advance(to: Fixtures.date(minutes: 41))
        try await network.until("closed") { await group.phone(alex).interaction(link.id)?.state.isFinal == true }
        #expect(await group.phone(alex).interaction(link.id)?.state == .ended(.nobodyUp))
        for person in [alex, maya, jake] { #expect(await group.phone(person).plan(group.origin)?.attendees.peers.count == 3) }
        #expect(await group.phone(sam).plan(group.origin) == nil)
        await network.shutdown()
    }

    @Test func leavingShrinksEveryoneElsesPlanAndTheLastOneEnds() async throws {
        let group = Group()
        let network = group.network
        let leave = try await group.suggest(.leave, by: jake)
        await network.deliver()
        try await network.until("plans shrank") {
            let alexs = await group.phone(alex).plan(group.origin)?.attendees.peers
            let mayas = await group.phone(maya).plan(group.origin)?.attendees.peers
            return alexs == [alex, maya] && mayas == [alex, maya]
        }
        // Jake's own plan ended, withdrawn; his leave ended too.
        try await network.until("Jake's plan ended") { await group.phone(jake).interaction(group.roots[jake]!.id)?.state.isFinal == true }
        try await network.until("the others' notes closed") {
            let alexs = await group.phone(alex).changes()
            return !alexs.isEmpty && alexs.allSatisfy(\.state.isFinal)
        }
        #expect(await group.phone(jake).interaction(group.roots[jake]!.id)?.state == .ended(.withdrawn))
        #expect(await group.phone(jake).interaction(leave.id)?.state == .ended(.withdrawn))
        // Nothing was disclosed: the notices and acknowledgments carry no values.
        #expect(network.transcript == ["Jake > Alex: propose", "Jake > Maya: propose", "Alex > Jake: accept", "Maya > Jake: accept"])
        // The others' timelines show it.
        #expect(await group.phone(alex).changes().map(\.state) == [.ended(.withdrawn)])
        #expect(await group.phone(alex).plan(group.origin)?.revision == 1)

        // Then Maya leaves: Alex is left alone, and the plan ends for him.
        try await group.suggest(.leave, by: maya)
        await network.deliver()
        try await network.until("Alex's plan ended") {
            await group.phone(alex).interaction(group.roots[alex]!.id)?.state == .ended(.withdrawn)
        }
        #expect(try await group.phone(alex).ledger.isRetired(group.origin))
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func leavingEndsAnOpenSuggestionQuietly() async throws {
        let group = Group()
        let network = group.network
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("cards up") { await Self.cardsUp(group, [maya, jake]) }
        try await group.suggest(.leave, by: jake)
        await network.deliver()
        try await network.until("suggestion ended") { await group.phone(alex).interaction(link.id)?.state.isFinal == true }
        #expect(await group.phone(alex).interaction(link.id)?.state == .ended(.nobodyUp))
        try await network.until("Maya's card closed") {
            await group.phone(maya).changes().filter { $0.proposal != nil }.allSatisfy(\.state.isFinal)
        }
        try await network.until("Alex's plan shrank") { await group.phone(alex).plan(group.origin)?.attendees.peers == [alex, maya] }
        #expect(await group.phone(alex).plan(group.origin)?.time == Fixtures.tonight)
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }
}
