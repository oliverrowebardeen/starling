import Foundation
@testable import DownFor
import StarlingCore
import StarlingFakes
import Testing

/// The owner's two-phone run (issue #95, 2026-10-02).
@Suite(.timeLimit(.minutes(1))) struct DeviceTestTwoTests {
    /// "dinner", Ask directly, on A; nothing on B. A is never told B is
    /// down, or shown a plan naming B, until B says I'm in: A's request
    /// waits with no card. Only then does A's card read "both down".
    @Test func aStarterHearsNothingOfAnInvitedFriendUntilTheyAccept() async throws {
        let world = World(2)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        // No time given: the request is open until midnight.
        let mine = try await a.down(for: ["dinner"], time: nil, with: [b], mode: .invite)
        try await eventually("B's invitation") { await !b.lifecycle.invitations.isEmpty }
        let theirs = try #require(await b.lifecycle.invitations.first)
        try await b.waitForProposal(theirs)

        // B does nothing. A waits, with no card and nothing that says B is
        // down.
        try await Task.sleep(for: .milliseconds(500))
        #expect(await a.lifecycle.state(mine) == .negotiating)
        #expect(await a.lifecycle.interaction(mine)?.proposal == nil)
        #expect(await !a.lifecycle.lifecycleEvents.contains { if case .proposalReady = $0 { true } else { false } })

        // The invitation leaves an hour's notice, on the half hour: never
        // the next free half-hour (it is 19:00 in the harness).
        let offered = try #require(await b.lifecycle.interaction(theirs)?.proposal)
        let start = try #require(DownForProfile.slot(of: offered.terms)?.start)
        #expect(start >= T.now.addingTimeInterval(3600))
        #expect(Int(start.timeIntervalSince1970) % 1800 == 0)

        // B says I'm in: now, and only now, A's card names B.
        try await b.imIn(theirs)
        try await a.waitForProposal(mine)
        let card = try #require(await a.lifecycle.interaction(mine)?.proposal)
        #expect(card.participants == [a.id, b.id])
        let facts = ProposalFacts(
            skill: DownFor.ref, friendNames: ["Riley"], activity: try Keyword("dinner"),
            time: DownForProfile.slot(of: card.terms), place: nil, timeZone: T.utc
        )
        #expect(ProposalTemplate.sentence(facts, now: T.now) == "You and Riley are both down for dinner. Tonight at 8 PM?")
        try await a.imIn(mine)
        try await a.waitFor(.planned, mine)
        try await b.waitFor(.planned, theirs)
        await world.expectCleanLifecycles()
    }

    /// A quiet pair plan leaves an hour's notice too, on the half hour.
    @Test func aPairPlanLeavesAnHoursNotice() async throws {
        let world = World(2)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        let mine = try await a.down(for: ["boba"], time: nil, with: [b])
        _ = try await b.down(for: ["boba"], time: nil, with: [a])
        try await a.waitForProposal(mine)
        let card = try #require(await a.lifecycle.interaction(mine)?.proposal)
        let start = try #require(DownForProfile.slot(of: card.terms)?.start)
        #expect(start == T.now.addingTimeInterval(3600))
    }
}
