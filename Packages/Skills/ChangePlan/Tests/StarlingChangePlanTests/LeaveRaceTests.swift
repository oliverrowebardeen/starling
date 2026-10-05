import Foundation
import StarlingChaining
import StarlingChangePlan
import StarlingCore
import StarlingFakes
import Testing

/// Final review of PR #111, finding 1: a leave and a committed change reach
/// a phone in either order, and every phone still ends on the same plan and
/// revision. Alex, Maya, Jake, and Sam; Maya suggests the later time,
/// everyone says yes, and Jake leaves at the old revision.
@Suite struct LeaveRaceTests {
    let alex = Fixtures.alex, maya = Fixtures.maya, jake = Fixtures.jake, sam = Fixtures.sam
    var everyone: [PeerID] { [alex, maya, jake, sam] }

    /// Maya's change, committed after everyone's yes, and Jake's leave sent
    /// at revision 0, his confirmation lost. Frames in `losing` are lost
    /// once, after the yeses.
    func race(losing frames: [String]) async throws -> Group {
        let group = Group(people: everyone)
        let network = group.network
        try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: maya)
        await network.deliver()
        try await network.until("cards up") {
            for person in [alex, jake, sam] where await group.openCard(of: person) == nil { return false }
            return true
        }
        for person in [alex, jake, sam] {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        for frame in frames { network.drop(frame) }
        // Jake's confirmation never reaches him before he leaves.
        network.drop("Maya > Jake: accept")
        // The yeses reach Maya, who commits and confirms.
        await network.deliver()
        try await network.until("Maya committed") { await group.phone(maya).plan(group.origin)?.revision == 1 }
        #expect(await group.phone(jake).plan(group.origin)?.revision == 0)
        try await group.suggest(.leave, by: jake)
        await network.deliver()
        return group
    }

    func expectOnePlan(_ group: Group) async throws {
        for person in [alex, maya, sam] {
            let plan = try #require(await group.phone(person).plan(group.origin))
            #expect(plan.revision == 2)
            #expect(plan.attendees.peers == [alex, maya, sam])
            #expect(plan.time == Fixtures.later)
        }
        #expect(await group.phone(jake).plan(group.origin) == nil)
        // The plan can still change: the next suggestion names revision 2 everywhere.
        try await group.suggest(.change(time: nil, activity: Fixtures.dinner, adding: nil), by: alex)
        await group.network.deliver()
        try await group.network.until("cards up again") {
            for person in [maya, sam] where await group.openCard(of: person) == nil { return false }
            return true
        }
        for person in [maya, sam] {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        await group.network.deliver()
        try await group.network.until("revision 3") {
            for person in [alex, maya, sam] where await group.phone(person).plan(group.origin)?.revision != 3 { return false }
            return true
        }
        #expect(await group.network.problems().isEmpty)
    }

    @Test func theLeaveReachesAPhoneBeforeTheConfirmation() async throws {
        // Sam hears Jake left first, then Maya's (resent) confirmation.
        let group = try await race(losing: ["Maya > Sam: accept"])
        let network = group.network
        try await network.until("Sam applied the leave") { await group.phone(sam).plan(group.origin)?.revision == 1 }
        #expect(await group.phone(sam).plan(group.origin)?.time == Fixtures.tonight)
        try await ReliabilityTests.resend(group, after: 5, from: group.phone(maya))
        try await network.until("Sam applied the change") { await group.phone(sam).plan(group.origin)?.revision == 2 }
        try await network.until("Alex and Maya at 2") {
            await ReliabilityTests.revisions(group, [alex, maya]) == [2, 2]
        }
        try await expectOnePlan(group)
        await network.shutdown()
    }

    @Test func theConfirmationReachesAPhoneBeforeTheLeave() async throws {
        // Sam applies Maya's change first, then hears (on a resend) that Jake left.
        let group = try await race(losing: ["Jake > Sam: propose"])
        let network = group.network
        try await network.until("Sam applied the change") { await group.phone(sam).plan(group.origin)?.revision == 1 }
        #expect(await group.phone(sam).plan(group.origin)?.time == Fixtures.later)
        try await ReliabilityTests.resend(group, after: 5, from: group.phone(jake))
        try await network.until("Sam applied the leave") { await group.phone(sam).plan(group.origin)?.revision == 2 }
        try await network.until("Alex and Maya at 2") {
            await ReliabilityTests.revisions(group, [alex, maya]) == [2, 2]
        }
        try await expectOnePlan(group)
        await network.shutdown()
    }
}
