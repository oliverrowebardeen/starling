import Foundation
import StarlingChaining
import StarlingChangePlan
import StarlingCore
import StarlingFakes
import Testing

/// One change to a plan at a time on each phone (ADR 0023): a change holds
/// the plan before its first offer or its yes, and every ending releases it.
/// Another skill's change (Pick a place) is played by holding the plan for
/// a conversation of its own.
@Suite struct HoldTests {
    let alex = Fixtures.alex, maya = Fixtures.maya, jake = Fixtures.jake

    static func holders(_ group: Group, _ people: [PeerID]) async -> [ConversationID?] {
        var all: [ConversationID?] = []
        for person in people { all.append(await group.phone(person).holds.holder(of: group.origin)) }
        return all
    }

    @Test func aSuggestionCannotStartWhileAnotherChangeHoldsThePlan() async throws {
        let group = Group()
        let network = group.network
        let place = ConversationID()
        #expect(await group.phone(maya).holds.hold(group.origin, for: place))
        await #expect(throws: ChangePlanError.planBusy) {
            try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: maya)
        }
        await network.deliver()
        #expect(network.transcript.isEmpty)
        #expect(await group.phone(maya).holds.holder(of: group.origin) == place)
        // The coordinator ends the refused start as failed.
        let phone = group.phone(maya)
        var refused = try #require(await phone.changes().first)
        try refused.apply(.failed, at: Timestamp(group.clock.now))
        try await phone.store.save(refused)
        // Once that change ends, a suggestion starts and holds the plan.
        await group.phone(maya).holds.release(group.origin, for: place)
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: maya)
        #expect(await group.phone(maya).holds.holder(of: group.origin) == link.conversation)
        await network.shutdown()
    }

    @Test func noYesWhileAnotherChangeHoldsThePlan() async throws {
        let group = Group()
        let network = group.network
        // Alex suggests a time while Maya is picking a new place.
        let place = ConversationID()
        #expect(await group.phone(maya).holds.hold(group.origin, for: place))
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("cards up") { await ReliabilityTests.cardsUp(group) }
        let card = try await group.card(of: maya)
        await #expect(throws: ChangePlanError.planBusy) {
            try await group.phone(maya).service.answer(card.id, with: .accept(proposal: 1))
        }
        await network.deliver()
        #expect(DurabilityTests.sent(network, "Maya > Alex: accept") == 0)
        #expect(await group.phone(maya).interaction(card.id)?.state == .proposed)
        #expect(try await group.phone(maya).journal.records().isEmpty)
        // Jake says yes; without Maya's, the window closes on no change.
        try await group.phone(jake).service.answer(try await group.card(of: jake).id, with: .accept(proposal: 1))
        await network.deliver()
        group.clock.advance(to: Fixtures.date(minutes: 41))
        try await network.until("Alex's ended") { await group.phone(alex).interaction(link.id)?.state.isFinal == true }
        await network.deliver()
        #expect(await group.phone(alex).interaction(link.id)?.state == .ended(.nobodyUp))
        #expect(await ReliabilityTests.revisions(group, [alex, maya, jake]) == [0, 0, 0])
        #expect(await group.phone(maya).holds.holder(of: group.origin) == place)
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func theYesIsPossibleOnceTheOtherChangeEnds() async throws {
        let group = Group()
        let network = group.network
        let place = ConversationID()
        #expect(await group.phone(maya).holds.hold(group.origin, for: place))
        try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("cards up") { await ReliabilityTests.cardsUp(group) }
        let card = try await group.card(of: maya)
        await #expect(throws: ChangePlanError.planBusy) {
            try await group.phone(maya).service.answer(card.id, with: .accept(proposal: 1))
        }
        await group.phone(maya).holds.release(group.origin, for: place)
        for person in [maya, jake] {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        await network.deliver()
        try await network.until("all applied") { await ReliabilityTests.revisions(group, [alex, maya, jake]) == [1, 1, 1] }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aPlannedChangeReleasesThePlanEverywhere() async throws {
        let group = Group()
        let network = group.network
        let link = try await ReliabilityTests.agreed(group)
        // While it is open, it holds each phone that took part.
        try await network.until("all applied") { await ReliabilityTests.revisions(group, [alex, maya, jake]) == [1, 1, 1] }
        try await network.until("released") { await Self.holders(group, [alex, maya, jake]) == [nil, nil, nil] }
        #expect(await group.phone(alex).interaction(link.id)?.state == .planned)
        await network.shutdown()
    }

    @Test func noAgreementAWithdrawalAndAPassReleaseThePlan() async throws {
        let group = Group()
        let network = group.network
        // Nobody up: Maya says yes, Jake passes, the window closes.
        let first = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        #expect(await group.phone(alex).holds.holder(of: group.origin) == first.conversation)
        await network.deliver()
        try await network.until("cards up") { await ReliabilityTests.cardsUp(group) }
        try await group.phone(maya).service.answer(try await group.card(of: maya).id, with: .accept(proposal: 1))
        #expect(await group.phone(maya).holds.holder(of: group.origin) == first.conversation)
        try await group.phone(jake).service.answer(try await group.card(of: jake).id, with: .pass)
        await network.deliver()
        group.clock.advance(to: Fixtures.date(minutes: 41))
        try await network.until("Alex's ended") { await group.phone(alex).interaction(first.id)?.state.isFinal == true }
        await network.deliver()
        try await network.until("released") { await Self.holders(group, [alex, maya, jake]) == [nil, nil, nil] }

        // Withdrawn: Maya said yes, then Alex takes it back.
        let second = try await group.suggest(.change(time: nil, activity: Fixtures.dinner, adding: nil), by: alex, expiresIn: 60)
        await network.deliver()
        try await network.until("Maya's card") { await group.openCard(of: maya) != nil }
        try await group.phone(maya).service.answer(try await group.card(of: maya).id, with: .accept(proposal: 1))
        await network.deliver()
        #expect(await group.phone(maya).holds.holder(of: group.origin) == second.conversation)
        await group.phone(alex).service.withdraw(second.id)
        await network.deliver()
        try await network.until("released again") { await Self.holders(group, [alex, maya, jake]) == [nil, nil, nil] }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func leavingNeedsNoHold() async throws {
        let group = Group()
        let network = group.network
        // Jake leaves while another change holds his plan.
        let place = ConversationID()
        #expect(await group.phone(jake).holds.hold(group.origin, for: place))
        try await group.suggest(.leave, by: jake)
        await network.deliver()
        try await network.until("plans shrank") {
            for person in [alex, maya] where await group.phone(person).plan(group.origin)?.attendees.peers != [alex, maya] { return false }
            return true
        }
        #expect(await Self.holders(group, [alex, maya]) == [nil, nil])
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aRestoredYesHoldsThePlanAgain() async throws {
        let group = Group()
        let network = group.network
        try await ReliabilityTests.agreed(group, losing: [("Alex > Jake: accept", skipping: 0)])
        try await network.until("Maya applied") { await group.phone(maya).plan(group.origin)?.revision == 1 }
        let card = try #require(await group.phone(jake).changes().first)
        await group.phone(jake).restart()
        #expect(await group.phone(jake).holds.holder(of: group.origin) == card.conversation)
        try await ReliabilityTests.resend(group, after: 5, from: group.phone(alex))
        try await network.until("Jake applied") { await group.phone(jake).plan(group.origin)?.revision == 1 }
        #expect(await group.phone(jake).holds.holder(of: group.origin) == nil)
        await network.shutdown()
    }

    @Test func aRestoredYesThatFindsThePlanHeldEndsWithNoChange() async throws {
        let group = Group()
        let network = group.network
        try await ReliabilityTests.agreed(group, losing: [("Alex > Jake: accept", skipping: 0)])
        try await network.until("Maya applied") { await group.phone(maya).plan(group.origin)?.revision == 1 }
        let card = try #require(await group.phone(jake).changes().first)
        // Another skill restores its own change to the plan first.
        let place = ConversationID()
        await group.phone(jake).restart { holds in _ = await holds.hold(group.origin, for: place) }
        try await network.until("Jake's card ended") { await group.phone(jake).interaction(card.id)?.state.isFinal == true }
        #expect(await group.phone(jake).interaction(card.id)?.state == .ended(.nobodyUp))
        #expect(try await group.phone(jake).ledger.isRetired(card.conversation))
        #expect(try await group.phone(jake).journal.records().isEmpty)
        #expect(await group.phone(jake).holds.holder(of: group.origin) == place)
        #expect(await group.phone(jake).plan(group.origin)?.revision == 0)
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }
}
