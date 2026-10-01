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
        let mine = try await a.downEach(for: ["boba"], time: [T.slot(19, 21)], with: [b, c], expires: T.at(21))

        for id in mine {
            try await a.waitFor(.ended(.nobodyUp), id)
            #expect(await !a.lifecycle.reached(.proposed, id))
        }
        // C never answered, ran the model, or saw anything.
        #expect(await c.lifecycle.events.isEmpty)
        #expect(await world.wire.sent(by: c.id).isEmpty)
        // B learned the empty intersection and nothing more: no details.
        #expect(await world.wire.envelopes.allSatisfy { $0.body.kind == .psi })
        await world.expectCleanLifecycles()
    }

    /// A group plan is an explicit step (ADR 0011 amendment 17): A matches
    /// with B and with C, each on its own, then invites both, and the
    /// invitation names everyone.
    @Test func aGroupPlanIsAnInvitationAfterTheMatches() async throws {
        let world = World(3)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world["A"], world["B"], world["C"])

        let mine = try await a.downEach(for: ["boba"], with: [b, c])
        let bs = try await b.down(for: ["boba"], with: [a])
        let cs = try await c.down(for: ["boba"], with: [a])
        for (phone, id) in [(a, mine[0]), (a, mine[1]), (b, bs), (c, cs)] {
            try await phone.waitForProposal(id)
            // Each match is its own card, for two.
            #expect(await phone.lifecycle.interaction(id)?.proposal?.participants.count == 2)
            try await phone.imIn(id)
        }
        for (phone, id) in [(a, mine[0]), (a, mine[1]), (b, bs), (c, cs)] { try await phone.waitFor(.planned, id) }

        // Then A invites the friends it matched with, as a group.
        let group = try await a.down(for: ["boba"], with: [b, c], mode: .invite)
        var invitations: [InteractionID] = []
        for phone in [b, c] {
            try await eventually("\(phone.name)'s invitation") { await !phone.lifecycle.invitations.isEmpty }
            let id = try #require(await phone.lifecycle.invitations.first)
            try await phone.waitForProposal(id)
            #expect(await phone.lifecycle.interaction(id)?.proposal?.participants == [a.id, b.id, c.id])
            try await phone.imIn(id)
            invitations.append(id)
        }
        try await a.waitForProposal(group)
        #expect(await a.lifecycle.interaction(group)?.proposal?.participants == [a.id, b.id, c.id])
        try await a.imIn(group)
        try await a.waitFor(.planned, group)
        for (phone, id) in zip([b, c], invitations) {
            try await phone.waitFor(.planned, id)
            #expect(await phone.lifecycle.interaction(id)?.plan?.attendees.peers == [a.id, b.id, c.id])
        }
        await world.expectCleanLifecycles()
    }

    /// A pass and no answer at all look the same to the starter: in what
    /// crosses the wire, in what its lifecycle shows, and in when it ends
    /// (the owner window), not just in what is shown (review of PR #56,
    /// finding 4).
    @Test func aPassIsInvisibleToTheStarter() async throws {
        let passed = try await Self.pairWhereBLeaves(byPassing: true)
        let silent = try await Self.pairWhereBLeaves(byPassing: false)
        // Nothing B sent after its card differs between the two.
        #expect(passed.afterCard.isEmpty && silent.afterCard.isEmpty)
        #expect(passed.startersEvents == silent.startersEvents)
        // Both ended when the window passed, not when B answered.
        #expect(passed.endedAfter >= .milliseconds(1_800) && silent.endedAfter >= .milliseconds(1_800))
    }

    struct Departure: Sendable {
        let afterCard: [MessageBody.Kind]
        let startersEvents: [String]
        let endedAfter: Duration
    }

    /// A and B are both down; A says I'm in; B passes or never answers.
    /// Returns what B sent after its card, A's lifecycle event kinds, and
    /// how long A's request took to end.
    static func pairWhereBLeaves(byPassing: Bool) async throws -> Departure {
        let world = World(2)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        let mine = try await a.down(for: ["boba"], with: [b])
        let theirs = try await b.down(for: ["boba"], with: [a])
        try await a.waitForProposal(mine)
        try await b.waitForProposal(theirs)
        let sentBefore = await world.wire.sent(by: b.id).count
        let clock = ContinuousClock()
        let cardShown = clock.now
        try await a.imIn(mine)
        if byPassing {
            try await b.pass(theirs)
            try await b.waitFor(.ended(.declined), theirs)
        }
        try await a.waitFor(.ended(.nobodyUp), mine)
        let endedAfter = cardShown.duration(to: clock.now)
        await world.expectCleanLifecycles()

        let afterCard = await world.wire.sent(by: b.id).dropFirst(sentBefore).map(\.body.kind)
        let events = await a.lifecycle.lifecycleEvents.map { event -> String in
            switch event {
            case .proposalReady(let proposal): "proposalReady(\(proposal.revision), \(proposal.participants.count))"
            default: "\(event)"
            }
        }
        return Departure(afterCard: afterCard, startersEvents: events, endedAfter: endedAfter)
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

        // A's ask of C is its own interaction, and goes ahead.
        let mine = try await a.down(for: ["boba"], with: [c])
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
        let world = World(1)
        try await world.start()
        defer { Task { await world.stop() } }
        let b = world["A"]
        let mallory = try Mallory(hub: world.hub)
        try await mallory.start()
        defer { Task { await mallory.stop() } }
        let mine = try await b.down(for: ["boba"], with: [], extraParticipants: [mallory.id])
        let conversation = try await mallory.findSharedTime(with: b.id)
        try await mallory.send(.query(try Query(issue: .activity, candidates: .keywords([T.keyword("boba")]))), to: b.id, in: conversation)
        _ = try await mallory.next(.answer, in: conversation)

        // The starter proposes, then proposes again in a later round: B's
        // card moves to a new revision.
        let firstTerms = try Terms([.time: .slots([T.slot(19.5, 20.5)]), .activity: .keywords([T.keyword("boba")])])
        let secondTerms = try Terms([.time: .slots([T.slot(20.5, 21.5)]), .activity: .keywords([T.keyword("boba")])])
        try await mallory.send(.propose(try Proposal(round: 0, terms: firstTerms)), to: b.id, in: conversation)
        try await b.waitForProposal(mine)
        let first = try #require(await b.lifecycle.interaction(mine)?.proposal)
        try await mallory.send(.propose(try Proposal(round: 1, terms: secondTerms)), to: b.id, in: conversation)
        try await b.waitForProposal(mine, revision: first.revision + 1)
        let second = try #require(await b.lifecycle.interaction(mine)?.proposal)

        // A tap on the old card is refused by the service and by the lifecycle.
        await #expect(throws: DownForError.staleProposal(current: second.revision)) {
            try await b.service.answer(mine, with: .accept(proposal: first.revision))
        }
        var copy = try #require(await b.lifecycle.interaction(mine))
        #expect(throws: StaleProposal.self) { try copy.apply(.ownerAccepted(revision: first.revision), at: Timestamp(T.now)) }

        // B's I'm in names only the terms of the card B tapped.
        try await b.imIn(mine)
        let accept = try await mallory.next(.accept, in: conversation)
        if case .accept(let acceptance) = accept.body { #expect(acceptance.terms == secondTerms) }
        await world.expectCleanLifecycles()
    }
}
