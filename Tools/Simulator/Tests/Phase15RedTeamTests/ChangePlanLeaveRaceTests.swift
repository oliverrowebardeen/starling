import Foundation
import StarlingChangePlan
import StarlingCore
import Testing

struct ChangePlanLeaveRaceTests {
    /// The leaver misses the commit and leaves at revision zero. Another
    /// member sees either the leave or confirmation first, after real Inbox.
    private func race(adding: Bool, leaveFirst: Bool, losingForward: Bool = false) async throws -> ChangeWorld {
        let world = try await ChangeWorld.make(members: 4)
        let a = world.phones[0], b = world.phones[1], c = world.phones[2], d = world.phones[3], n = world.phones[4]
        await b.relay.dropConfirmations()
        if leaveFirst { await c.relay.dropConfirmations() }
        if losingForward { await n.relay.drop(.counter) }
        let change = try await world.start(adding ? .change(time: nil, activity: nil, adding: n.id) : ChangeWorld.change)
        for phone in [b, c, d] { try await phone.accept(change.conversation) }
        if adding { try await n.accept(change.conversation) }
        try await a.waitRevision(1, origin: world.origin)
        try await d.waitRevision(1, origin: world.origin)
        if adding { try await n.waitRevision(1, origin: world.origin) }
        try await P15.eventually("leaver misses the committed change") { await b.relay.lost.count == 1 }
        #expect(try await b.plan(world.origin).revision == 0)
        if leaveFirst {
            try await P15.eventually("member misses the committed change") { await c.relay.lost.count == 1 }
            #expect(try await c.plan(world.origin).revision == 0)
        } else {
            try await c.waitRevision(1, origin: world.origin)
            if !losingForward { await c.relay.drop(.propose) }
        }
        _ = try await world.start(.leave, by: 1)
        for phone in [a, d] { try await phone.waitRevision(2, origin: world.origin) }
        if leaveFirst {
            try await c.waitRevision(1, origin: world.origin)
            #expect(try await c.plan(world.origin).attendees.peers == [a.id, c.id, d.id])
            #expect(try await c.plan(world.origin).activity == Keyword("boba"))
            #expect(try await c.events.interaction(change.conversation)?.state == .confirmed)
        } else if !losingForward {
            try await P15.eventually("leave lost after member applied confirmation") { await c.relay.lost.count == 1 }
            #expect(try await c.plan(world.origin).attendees.peers.contains(b.id) == true)
        }
        return world
    }

    private func retry(_ world: ChangeWorld) async throws {
        let next = world.clock.now.addingTimeInterval(5)
        try await P15.eventually("leave or confirmation retry registered") { world.clock.deadlines.contains(next) }
        world.clock.advance(to: next)
    }

    private func checkConvergenceAndNextChange(_ world: ChangeWorld, adding: Bool) async throws {
        let stayed = [world.phones[0], world.phones[2], world.phones[3]] + (adding ? [world.phones[4]] : [])
        for phone in stayed {
            try await phone.waitRevision(2, origin: world.origin)
            #expect(try await phone.plan(world.origin).attendees.peers == stayed.map(\.id))
            #expect(try await phone.plan(world.origin).activity == (adding ? Keyword("boba") : ChangeWorld.changedActivity))
        }
        #expect(try await world.phones[1].root(world.origin).state == .ended(.withdrawn))
        // A subsequent change proves that every phone agrees on both the
        // revision and roster, and that the departed friend is not asked.
        let starter = adding ? 4 : 0
        let next = try await world.start(.change(time: nil, activity: Keyword("coffee"), adding: nil), by: starter)
        #expect(Set(next.participants) == Set(stayed.filter { $0.id != world.phones[starter].id }.map(\.id)))
        for phone in stayed where phone.id != world.phones[starter].id { try await phone.accept(next.conversation) }
        for phone in stayed {
            try await phone.waitRevision(3, origin: world.origin)
            #expect(try await phone.plan(world.origin).activity == Keyword("coffee"))
            #expect(try await phone.plan(world.origin).attendees.peers == stayed.map(\.id))
        }
        #expect(await world.phones[1].agent.received.allSatisfy { $0.conversation != next.conversation })
        await world.checkHealthy()
    }

    @Test(arguments: [false, true], [false, true])
    func pc39ALeaveAndConfirmationCommuteWithOrWithoutAnAddedFriend(adding: Bool, leaveFirst: Bool) async throws {
        let world = try await race(adding: adding, leaveFirst: leaveFirst)
        defer { Task { await world.stop() } }
        try await retry(world)
        try await checkConvergenceAndNextChange(world, adding: adding)
    }

    @Test(arguments: [false, true])
    func pc40ALostForwardedDepartureReachesTheAddedFriendAfterRetryOrRestart(restart: Bool) async throws {
        let world = try await race(adding: true, leaveFirst: false, losingForward: true)
        defer { Task { await world.stop() } }
        let a = world.phones[0], b = world.phones[1], n = world.phones[4]
        try await P15.eventually("forwarded departure lost at added friend") { await n.relay.lost.count == 1 }
        let forwarded = try #require(await n.relay.lost.first)
        guard case .counter(let notice) = forwarded.body else { Issue.record("missing forwarded departure"); return }
        #expect(notice.terms.values.isEmpty)
        #expect(notice.inReplyTo == ChangePlanService.departureDigest(origin: world.origin, round: 0, leaver: b.id))
        #expect(forwarded.sender == a.id && forwarded.chainedFrom == world.origin)
        #expect(await b.sent().allSatisfy { $0.recipient != n.id || $0.body.kind == .hello })
        #expect(try await n.plan(world.origin).revision == 1)
        try await P15.eventually("forwarded departure retained for recovery") {
            try await a.journal.records().contains {
                if case .leaving(let delivery) = $0 { delivery.forwarding == b.id && delivery.pending == [n.id] } else { false }
            }
        }
        if restart { try await a.restart() } else { try await retry(world) }
        try await n.waitRevision(2, origin: world.origin)
        try await P15.eventually("forwarded departure acknowledged") {
            try await a.journal.records().allSatisfy { if case .leaving = $0 { false } else { true } }
        }
        try await checkConvergenceAndNextChange(world, adding: true)
    }
}
