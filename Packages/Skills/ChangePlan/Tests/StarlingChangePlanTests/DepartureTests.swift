import Foundation
import StarlingChaining
import StarlingChangePlan
import StarlingCore
import StarlingFakes
import Testing

/// Final review of PR #111, finding 6: what a departure leaves behind.
@Suite struct DepartureTests {
    let alex = Fixtures.alex, maya = Fixtures.maya, jake = Fixtures.jake, sam = Fixtures.sam

    @Test func someoneWhoLeftIsNoLongerOwedAConfirmation() async throws {
        let group = Group()
        let network = group.network
        // Alex's change commits; Jake's confirmation is lost, and he leaves.
        try await ReliabilityTests.agreed(group, losing: [("Alex > Jake: accept", skipping: 0)])
        try await network.until("Maya applied") { await group.phone(maya).plan(group.origin)?.revision == 1 }
        try await group.suggest(.leave, by: jake)
        await network.deliver()
        try await network.until("Alex applied the leave") { await group.phone(alex).plan(group.origin)?.attendees.peers == [alex, maya] }
        // Alex owes nothing more: no confirmation is resent to Jake.
        try await network.until("delivery done") {
            (try? await group.phone(alex).journal.records().contains(where: \.isConfirming)) == false
        }
        let sent = network.transcript.count
        group.clock.advance(to: group.clock.now.addingTimeInterval(60))
        await network.settle()
        await network.deliver()
        #expect(!network.transcript.dropFirst(sent).contains("Alex > Jake: accept"))
        await network.shutdown()
    }

    @Test func twoCopiesOfOneLeaveNoticeApplyOnce() async throws {
        let group = Group()
        let network = group.network
        let phone = group.phone(maya)
        await phone.journal.hold { $0.isDeparted }
        network.drop("Jake > Maya: propose")
        try await group.suggest(.leave, by: jake)
        await network.deliver()
        let frame = try #require(await group.phone(jake).transport.sent.last { $0.peer == maya })
        let notice = try EnvelopeCodec().decode(frame.frame.bytes)
        // The same notice arrives twice while the first is being recorded.
        let first = Task { await phone.service.handle(.message(notice)) }
        try await network.until("first held") { await phone.journal.held == 1 }
        let second = Task { await phone.service.handle(.message(notice)) }
        await network.settle()
        let held = await phone.journal.held
        await phone.journal.release()
        await first.value
        await second.value
        await network.settle()
        #expect(held == 1)
        #expect(try await phone.journal.records().filter(\.isDeparted).count == 1)
        #expect(await phone.changes().count == 1)
        #expect(await phone.plan(group.origin)?.revision == 1)
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func anAddedFriendWhoLeavesRetiresTheirPlansConversationFirst() async throws {
        let group = Group(extra: [sam])
        let network = group.network
        try await group.suggest(.change(time: nil, activity: nil, adding: sam), by: alex)
        await network.deliver()
        try await network.until("cards up") { await ReliabilityTests.cardsUp(group) }
        for person in [maya, jake] {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        await network.deliver()
        try await network.until("Sam's card up") { await group.openCard(of: sam) != nil }
        try await group.phone(sam).service.answer(try await group.card(of: sam).id, with: .accept(proposal: 1))
        await network.deliver()
        try await network.until("Sam joined") { await group.phone(sam).plan(group.origin)?.revision == 1 }
        // Sam's plan lives in the change that added him.
        let holder = try #require(await group.phone(sam).changes().first { $0.state == .planned })
        try await group.suggest(.leave, by: sam)
        await network.deliver()
        try await network.until("Sam's plan ended") { await group.phone(sam).plan(group.origin) == nil }
        #expect(await group.phone(sam).interaction(holder.id)?.state == .ended(.withdrawn))
        #expect(try await group.phone(sam).ledger.isRetired(holder.conversation))
        #expect(try await group.phone(sam).ledger.isRetired(group.origin))
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }
}
