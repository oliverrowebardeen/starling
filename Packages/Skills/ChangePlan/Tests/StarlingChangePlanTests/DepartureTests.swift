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
        try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: sam), by: alex)
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

    /// Finding 4: Jake has left, but Alex has not heard yet, so Alex's next
    /// suggestion, a later time with Sam added, still asks Jake. Jake holds
    /// no plan; the offer, whose roster and time make a whole plan, is not
    /// an invite back in.
    @Test func someoneWhoLeftDoesNotReadAMembersOfferAsAnInvite() async throws {
        let group = Group(extra: [sam])
        let network = group.network
        network.drop("Jake > Alex: propose")
        try await group.suggest(.leave, by: jake)
        await network.deliver()
        try await network.until("Jake's plan ended") { await group.phone(jake).plan(group.origin) == nil }
        try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: sam), by: alex)
        await network.deliver()
        #expect(network.transcript.contains("Alex > Jake: propose"))
        await network.settle()
        #expect(await group.openCard(of: jake) == nil)
        #expect(await group.phone(jake).changes().allSatisfy { $0.role == .initiator })
        await network.shutdown()
    }

    /// Finding 4: an invite opens a card only for the friend it adds, the
    /// last in its roster.
    @Test func anInviteOpensACardOnlyForTheFriendItAdds() async throws {
        let group = Group(extra: [sam])
        let phone = group.phone(sam)
        func invite(_ roster: [PeerID]) throws -> Envelope {
            let terms = try Terms([.people: .peers(roster), .activity: .keywords([Fixtures.boba]), .time: .slots([Fixtures.tonight])])
            return try Envelope(conversation: ConversationID(), sender: alex, recipient: sam, sequence: 0, sentAt: Timestamp(group.clock.now),
                                body: .propose(Proposal(round: 0, terms: terms, expiresAt: Timestamp(Fixtures.date(minutes: 60)))),
                                skill: ChangePlan.descriptor.ref, mode: .invite, chainedFrom: group.origin)
        }
        await phone.service.handle(.message(try invite([alex, sam, maya, jake])))
        await group.network.settle()
        #expect(await phone.changes().isEmpty)
        await phone.service.handle(.message(try invite([alex, maya, jake, sam])))
        try await group.network.until("Sam's card") { await group.openCard(of: sam) != nil }
        await group.network.shutdown()
    }

    /// Re-review of PR #111, item 1: Sam joined through Alex's change at
    /// revision 0. A departure passed on counts only from Alex, the
    /// suggester who added Sam, and only for a revision Sam joined over:
    /// nobody else can tell Sam that someone left.
    @Test func aPassedOnDepartureCountsOnlyFromWhoAddedThisPhone() async throws {
        let group = Group(extra: [sam])
        let network = group.network
        let phone = group.phone(sam)
        try await group.suggest(.change(time: nil, activity: nil, adding: sam), by: alex)
        await network.deliver()
        try await network.until("cards up") { await ReliabilityTests.cardsUp(group) }
        for person in [maya, jake] {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        await network.deliver()
        try await network.until("Sam's card up") { await group.openCard(of: sam) != nil }
        try await phone.service.answer(try await group.card(of: sam).id, with: .accept(proposal: 1))
        await network.deliver()
        try await network.until("Sam joined") { await phone.plan(group.origin)?.revision == 1 }
        func passedOn(from sender: PeerID, round: UInt16, leaver: PeerID = Fixtures.jake) throws -> Envelope {
            let digest = ChangePlanService.departureDigest(origin: group.origin, round: round, leaver: leaver)
            return try Envelope(conversation: ConversationID(), sender: sender, recipient: sam, sequence: 0, sentAt: Timestamp(group.clock.now),
                                body: .counter(Proposal(round: round, terms: Terms([:]), inReplyTo: digest)),
                                skill: ChangePlan.descriptor.ref, mode: .invite, chainedFrom: group.origin)
        }
        let sent = await phone.transport.sent.count
        // From Maya, who did not add Sam; and from Alex for revision 1, which Sam was in.
        await phone.service.handle(.message(try passedOn(from: maya, round: 0)))
        await phone.service.handle(.message(try passedOn(from: alex, round: 1)))
        await network.settle()
        #expect(await phone.plan(group.origin)?.attendees.peers == [alex, maya, jake, sam])
        #expect(await phone.transport.sent.count == sent)
        // From Alex, for revision 0: it applies, and is acknowledged.
        await phone.service.handle(.message(try passedOn(from: alex, round: 0)))
        try await network.until("Jake gone on Sam's phone") { await phone.plan(group.origin)?.attendees.peers == [alex, maya, sam] }
        #expect(await phone.plan(group.origin)?.revision == 2)
        #expect(await phone.transport.sent.count == sent + 1)
        await network.shutdown()
    }
}
