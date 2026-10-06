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
    let alex = Fixtures.alex, maya = Fixtures.maya, jake = Fixtures.jake, sam = Fixtures.sam, fay = Fixtures.fay
    var everyone: [PeerID] { [alex, maya, jake, sam] }

    /// Maya's change, committed after everyone's yes, and Jake's leave sent
    /// at revision 0, his confirmation lost. The change moves the time, or
    /// adds Fay, who then accepts too. Frames in `losing` are lost once,
    /// after the yeses.
    func race(adding friend: PeerID? = nil, losing frames: [String]) async throws -> Group {
        let group = Group(people: everyone, extra: friend.map { [$0] } ?? [])
        let network = group.network
        try await group.suggest(.change(time: friend == nil ? Fixtures.later : nil, activity: nil, adding: friend), by: maya)
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
        // The yeses reach Maya, who invites the friend if she adds one, and
        // then commits and confirms.
        await network.deliver()
        if let friend {
            try await network.until("the friend's card up") { await group.openCard(of: friend) != nil }
            try await group.phone(friend).service.answer(try await group.card(of: friend).id, with: .accept(proposal: 1))
            await network.deliver()
        }
        try await network.until("Maya committed") { await group.phone(maya).plan(group.origin)?.revision == 1 }
        #expect(await group.phone(jake).plan(group.origin)?.revision == 0)
        try await group.suggest(.leave, by: jake)
        await network.deliver()
        return group
    }

    /// Everyone left in the plan ends on one plan at revision 2, without
    /// Jake, and the plan can still change on every phone.
    func expectOnePlan(_ group: Group, adding friend: PeerID? = nil) async throws {
        let stayed = [alex, maya, sam] + (friend.map { [$0] } ?? [])
        try await group.network.until("everyone at 2") {
            for person in stayed where await group.phone(person).plan(group.origin)?.revision != 2 { return false }
            return true
        }
        for person in stayed {
            let plan = try #require(await group.phone(person).plan(group.origin))
            #expect(plan.revision == 2)
            #expect(plan.attendees.peers == stayed)
            #expect(plan.time == (friend == nil ? Fixtures.later : Fixtures.tonight))
        }
        #expect(await group.phone(jake).plan(group.origin) == nil)
        // The plan can still change: the next suggestion names revision 2 everywhere.
        let asked = stayed.filter { $0 != alex }
        try await group.suggest(.change(time: nil, activity: Fixtures.dinner, adding: nil), by: alex)
        await group.network.deliver()
        try await group.network.until("cards up again") {
            for person in asked where await group.openCard(of: person) == nil { return false }
            return true
        }
        for person in asked {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        await group.network.deliver()
        try await group.network.until("revision 3") {
            for person in stayed where await group.phone(person).plan(group.origin)?.revision != 3 { return false }
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
        try await expectOnePlan(group)
        await network.shutdown()
    }

    // Re-review of PR #111, item 1: Maya's change adds Fay, so Jake's
    // notices (sent to his roster at revision 0) never reach her. Maya
    // passes Jake's departure on, and Fay ends on the same plan.

    @Test func aFriendAddedWhileSomeoneLeavesHearsTheyLeftWhenTheLeaveReachesAPhoneFirst() async throws {
        let group = try await race(adding: fay, losing: ["Maya > Sam: accept"])
        let network = group.network
        try await network.until("Sam applied the leave") { await group.phone(sam).plan(group.origin)?.revision == 1 }
        #expect(await group.phone(sam).plan(group.origin)?.attendees.peers == [alex, maya, sam])
        try await ReliabilityTests.resend(group, after: 5, from: group.phone(maya))
        try await expectOnePlan(group, adding: fay)
        await network.shutdown()
    }

    @Test func aFriendAddedWhileSomeoneLeavesHearsTheyLeftWhenTheConfirmationReachesAPhoneFirst() async throws {
        let group = try await race(adding: fay, losing: ["Jake > Sam: propose"])
        let network = group.network
        try await network.until("Sam applied the change") { await group.phone(sam).plan(group.origin)?.revision == 1 }
        #expect(await group.phone(sam).plan(group.origin)?.attendees.peers == [alex, maya, jake, sam, fay])
        try await ReliabilityTests.resend(group, after: 5, from: group.phone(jake))
        try await expectOnePlan(group, adding: fay)
        await network.shutdown()
    }

    /// The forwarded departure is lost once; Maya resends it until Fay
    /// acknowledges it.
    @Test func aLostForwardedDepartureIsResentUntilTheFriendAcknowledgesIt() async throws {
        let group = try await race(adding: fay, losing: ["Maya > Fay: counter"])
        let network = group.network
        #expect(await group.phone(fay).plan(group.origin)?.revision == 1)
        try await ReliabilityTests.resend(group, after: 5, from: group.phone(maya))
        try await expectOnePlan(group, adding: fay)
        try await network.until("Maya's deliveries done") {
            (try? await group.phone(maya).journal.records().contains(where: \.isLeaving)) == false
        }
        await network.shutdown()
    }

    /// Maya's app quits before Fay acknowledges the departure it passes on;
    /// on relaunch it is resent at once.
    @Test func aPassedOnDepartureSurvivesTheSuggestersRestart() async throws {
        let group = try await race(adding: fay, losing: ["Maya > Fay: counter"])
        #expect(await group.phone(fay).plan(group.origin)?.revision == 1)
        await group.phone(maya).restart()
        await group.network.deliver()
        try await expectOnePlan(group, adding: fay)
        await group.network.shutdown()
    }
}
