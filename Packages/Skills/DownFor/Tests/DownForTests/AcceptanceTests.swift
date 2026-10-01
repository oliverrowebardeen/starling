import Foundation
@testable import DownFor
import StarlingCore
import StarlingFakes
import Testing

/// The lane's acceptance scenarios over LoopbackHub (lane plan, P15-B).
@Suite(.timeLimit(.minutes(1))) struct AcceptanceTests {
    @Test func aMutualPlanReachesPlannedOnBothSides() async throws {
        let world = World(2)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])

        let mine = try await a.down(for: ["boba"], time: [T.slot(19, 22)], with: [b])
        let theirs = try await b.down(for: ["boba"], time: [T.slot(20, 23)], with: [a])
        try await a.waitForProposal(mine)
        try await b.waitForProposal(theirs)

        // The card shows the same plan on both phones, from A's conversation.
        let card = try #require(await a.lifecycle.interaction(mine)?.proposal)
        let theirCard = try #require(await b.lifecycle.interaction(theirs)?.proposal)
        #expect(card.terms == theirCard.terms)
        #expect(card.participants == [a.id, b.id])
        #expect(card.terms[.time] == .slots([T.slot(20, 22)]))
        #expect(card.terms[.activity] == .keywords([T.keyword("boba")]))

        // Nobody is in a plan until both said "I'm in".
        try await a.imIn(mine)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await a.lifecycle.state(mine) == .confirmed)
        #expect(await b.lifecycle.state(theirs) == .proposed)

        try await b.imIn(theirs)
        try await a.waitFor(.planned, mine)
        try await b.waitFor(.planned, theirs)

        let planA = try #require(await a.lifecycle.interaction(mine)?.plan)
        let planB = try #require(await b.lifecycle.interaction(theirs)?.plan)
        #expect(planA.attendees == planB.attendees)
        #expect(planA.time == planB.time && planA.activity == planB.activity)
        #expect(planA.origin == planB.origin)
        #expect(planA.origin == (await a.lifecycle.interaction(mine))?.conversation)
        await world.expectCleanLifecycles()

        // Every envelope carried the skill.
        #expect(await world.wire.envelopes.allSatisfy { $0.skill == DownFor.ref })
    }

    @Test func nobodyUpEndsSilently() async throws {
        // The request's 2 hours pass in 0.7 s.
        let world = World(3, clock: testClock(speedup: 10_000))
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world["A"], world["B"], world["C"])

        // B is down, but at another time; C has no request at all.
        _ = try await b.down(for: ["boba"], time: [T.slot(22, 23)], with: [a])
        let mine = try await a.down(for: ["boba"], time: [T.slot(19, 21)], with: [b, c], expires: T.at(21))

        try await a.waitFor(.ended(.nobodyUp), mine)
        #expect(await !a.lifecycle.reached(.proposed, mine))
        // C never answered, ran the model, or saw anything.
        #expect(await c.lifecycle.events.isEmpty)
        #expect(await world.wire.sent(by: c.id).isEmpty)
        // B learned the empty intersection and nothing more: no details.
        #expect(await world.wire.envelopes.allSatisfy { $0.body.kind == .psi })
        await world.expectCleanLifecycles()
    }

    @Test func aThreePersonPlanAgreesOnTheSameRoster() async throws {
        let world = World(3)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world["A"], world["B"], world["C"])

        let ids = [
            try await a.down(for: ["boba"], with: [b, c]),
            try await b.down(for: ["boba", "tacos"], with: [a, c]),
            try await c.down(for: ["boba"], with: [a, b]),
        ]
        let phones = [a, b, c]
        for (phone, id) in zip(phones, ids) {
            try await eventually("\(phone.name) sees all three") {
                await phone.lifecycle.interaction(id)?.proposal?.participants.count == 3
            }
        }
        for (phone, id) in zip(phones, ids) { try await phone.imIn(id) }
        for (phone, id) in zip(phones, ids) { try await phone.waitFor(.planned, id) }

        var rosters: Set<[PeerID]> = []
        var origins: Set<ConversationID> = []
        for (phone, id) in zip(phones, ids) {
            let plan = try #require(await phone.lifecycle.interaction(id)?.plan)
            rosters.insert(plan.attendees.peers)
            origins.insert(plan.origin)
        }
        // The lowest starter's group carries everyone, in one roster.
        #expect(rosters == [[a.id, b.id, c.id]])
        #expect(origins.count == 1)
        await world.expectCleanLifecycles()
    }

    /// A pass and no answer at all look the same to the others: in what
    /// crosses the wire, in what the starter's lifecycle shows, and in when
    /// the group moves on (the owner window), not just in what is shown
    /// (review of PR #56, finding 4).
    @Test func aPassIsInvisibleToOthers() async throws {
        let passed = try await Self.groupWhereCLeaves(byPassing: true)
        let silent = try await Self.groupWhereCLeaves(byPassing: false)
        // Nothing C sent after its card differs between the two.
        #expect(passed.afterCard.isEmpty && silent.afterCard.isEmpty)
        #expect(passed.startersEvents == silent.startersEvents)
        // Both re-plans waited for the window, not for C.
        #expect(passed.replanAfter >= .milliseconds(1_800) && silent.replanAfter >= .milliseconds(1_800))
    }

    struct Departure: Sendable {
        let afterCard: [MessageBody.Kind]
        let startersEvents: [String]
        let replanAfter: Duration
    }

    /// A, B, and C are all down; A and B say I'm in; C passes or never
    /// answers. Returns what C sent after its card, A's lifecycle event
    /// kinds, and how long A took to re-plan for two.
    static func groupWhereCLeaves(byPassing: Bool) async throws -> Departure {
        let world = World(3)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world["A"], world["B"], world["C"])
        let ids = [
            try await a.down(for: ["boba"], with: [b, c]),
            try await b.down(for: ["boba"], with: [a, c]),
            try await c.down(for: ["boba"], with: [a, b]),
        ]
        for (phone, id) in zip([a, b, c], ids) { try await phone.waitForProposal(id) }
        let sentBefore = await world.wire.sent(by: c.id).count
        let clock = ContinuousClock()
        let cardShown = clock.now
        try await a.imIn(ids[0])
        try await b.imIn(ids[1])
        if byPassing {
            try await c.service.answer(ids[2], with: .pass)
            try await c.waitFor(.ended(.declined), ids[2])
        }

        // A and B just get a plan without C: no event says why.
        try await a.waitForProposal(ids[0], revision: 2)
        let replanAfter = cardShown.duration(to: clock.now)
        try await b.waitForProposal(ids[1], revision: 2)
        for (phone, id) in [(a, ids[0]), (b, ids[1])] {
            #expect(await phone.lifecycle.interaction(id)?.proposal?.participants == [a.id, b.id])
        }
        try await a.imIn(ids[0])
        try await b.imIn(ids[1])
        try await a.waitFor(.planned, ids[0])
        try await b.waitFor(.planned, ids[1])
        #expect(await a.lifecycle.interaction(ids[0])?.plan?.attendees.peers == [a.id, b.id])
        await world.expectCleanLifecycles()

        let afterCard = await world.wire.sent(by: c.id).dropFirst(sentBefore).map(\.body.kind)
        let events = await a.lifecycle.lifecycleEvents.map { event -> String in
            switch event {
            case .proposalReady(let proposal): "proposalReady(\(proposal.revision), \(proposal.participants.count))"
            default: "\(event)"
            }
        }
        return Departure(afterCard: afterCard, startersEvents: events, replanAfter: replanAfter)
    }

    @Test func aPeerWithoutTheSkillIsReportedAsUnsupported() async throws {
        let world = World(3)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world["A"], world["B"], world["C"])

        // B runs a build without Down for...; its card says so.
        let card = try AgentCard(model: .onDevice, capabilities: [], skills: [SkillRef(.findATime, SkillVersion(1))])
        await a.service.handle(.message(try Envelope(conversation: ConversationID(), sender: b.id, recipient: a.id, sequence: 0, sentAt: Timestamp(T.now), body: .hello(card))))
        #expect(DownForService.unsupported(among: [b.id, c.id], cards: [b.id: card]) == [b.id: .missing])

        let alone = try await a.down(for: ["boba"], with: [b])
        try await a.waitFor(.ended(.unsupported), alone)
        #expect(await world.wire.sent(by: a.id).filter { $0.recipient == b.id }.isEmpty)

        // With C, B is left out and the plan goes ahead.
        let mine = try await a.down(for: ["boba"], with: [b, c])
        let theirs = try await c.down(for: ["boba"], with: [a])
        try await a.waitForProposal(mine)
        #expect(await a.lifecycle.interaction(mine)?.proposal?.participants == [a.id, c.id])
        try await a.imIn(mine)
        try await c.waitForProposal(theirs)
        try await c.imIn(theirs)
        try await a.waitFor(.planned, mine)
        #expect(await world.wire.sent(by: a.id).filter { $0.recipient == b.id }.isEmpty)
        await world.expectCleanLifecycles()
    }

    @Test func aStaleImInNeverAcceptsNewerTerms() async throws {
        let world = World(3)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world["A"], world["B"], world["C"])

        let ids = [
            try await a.down(for: ["boba"], with: [b, c]),
            try await b.down(for: ["boba"], with: [a, c]),
            try await c.down(for: ["boba"], with: [a, b]),
        ]
        for (phone, id) in zip([a, b, c], ids) { try await phone.waitForProposal(id) }
        let first = try #require(await b.lifecycle.interaction(ids[1])?.proposal)

        // A and B say I'm in; C never answers, so after the window A
        // re-plans and B's card moves to a new revision.
        try await a.imIn(ids[0])
        try await b.imIn(ids[1])
        try await b.waitForProposal(ids[1], revision: first.revision + 1)
        let second = try #require(await b.lifecycle.interaction(ids[1])?.proposal)
        #expect(second.terms != first.terms)

        // A tap on the old card is refused by the service and by the lifecycle.
        await #expect(throws: DownForError.staleProposal(current: second.revision)) {
            try await b.service.answer(ids[1], with: .accept(proposal: first.revision))
        }
        var copy = try #require(await b.lifecycle.interaction(ids[1]))
        #expect(throws: StaleProposal.self) { try copy.apply(.ownerAccepted(revision: first.revision), at: Timestamp(T.now)) }

        // A's own "I'm in" again, and B's old acceptance still on the wire,
        // confirm nothing for B.
        try await a.waitForProposal(ids[0], revision: 2)
        try await a.imIn(ids[0])
        try await Task.sleep(for: .milliseconds(150))
        #expect(await b.lifecycle.state(ids[1]) == .proposed)
        #expect(await !a.lifecycle.reached(.planned, ids[0]))

        try await b.imIn(ids[1])
        try await b.waitFor(.planned, ids[1])
        #expect(await b.lifecycle.interaction(ids[1])?.plan?.attendees.peers == [a.id, b.id])
        // A confirmed only the terms of the card B tapped last.
        let confirmations = await world.wire.sent(by: a.id).filter { $0.recipient == b.id }.compactMap { envelope -> Terms? in
            if case .accept(let acceptance) = envelope.body { acceptance.terms } else { nil }
        }
        #expect(!confirmations.isEmpty && confirmations.allSatisfy { $0 == second.terms })
        await world.expectCleanLifecycles()
    }
}
