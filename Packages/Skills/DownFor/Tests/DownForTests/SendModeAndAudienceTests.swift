import Foundation
@testable import DownFor
import StarlingCore
import StarlingFakes
import StarlingNegotiation
import Testing

/// Core v2.1 (ADRs 0019 and 0020) and review finding 1, over LoopbackHub.
@Suite(.timeLimit(.minutes(1))) struct SendModeAndAudienceTests {
    // MARK: Finding 1: rosters name only friends each member asked

    @Test func friendsWhoDidNotAskEachOtherAreNeverNamedToEachOther() async throws {
        let world = World(3)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world["A"], world["B"], world["C"])
        // A asks both; B and C each ask only A.
        let mine = try await a.down(for: ["boba"], with: [b, c])
        let bs = try await b.down(for: ["boba"], with: [a])
        let cs = try await c.down(for: ["boba"], with: [a])
        try await a.waitForProposal(mine)
        try await Task.sleep(for: .milliseconds(200))

        // A's plan is a pair, and nobody's card or envelope names B and C
        // together.
        let card = try #require(await a.lifecycle.interaction(mine)?.proposal)
        #expect(card.participants.count == 2)
        for envelope in await world.wire.envelopes {
            if case .propose(let proposal) = envelope.body { #expect(proposal.terms[.people] == nil) }
        }
        // Each is offered its own pair, whoever else is up for it (final
        // privacy review, finding 2), and only A's plan is made: with
        // whichever of them A's card shows.
        try await b.waitForProposal(bs)
        try await c.waitForProposal(cs)
        let cards = [await b.lifecycle.interaction(bs)?.proposal, await c.lifecycle.interaction(cs)?.proposal].compactMap { $0 }
        #expect(cards.map(\.participants) == [[a.id, b.id], [a.id, c.id]])
        let chosen = try #require(card.participants.last)
        let (inIt, leftOut) = chosen == b.id ? ((b, bs), (c, cs)) : ((c, cs), (b, bs))
        try await a.imIn(mine)
        try await b.imIn(bs)
        try await c.imIn(cs)
        try await a.waitFor(.planned, mine)
        try await inIt.0.waitFor(.planned, inIt.1)
        #expect(await a.lifecycle.interaction(mine)?.plan?.attendees.peers == [a.id, chosen])
        // The other hears nothing more, as from a starter who never answered.
        try await leftOut.0.waitFor(.ended(.nobodyUp), leftOut.1)
        await world.expectCleanLifecycles()
    }

    @Test func friendsWhoAskedEachOtherAreGrouped() async throws {
        // The control: with everyone asking everyone, one group of three.
        let world = World(3)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world["A"], world["B"], world["C"])
        let ids = [
            try await a.down(for: ["boba"], with: [b, c]),
            try await b.down(for: ["boba"], with: [a, c]),
            try await c.down(for: ["boba"], with: [a, b]),
        ]
        for (phone, id) in zip([a, b, c], ids) {
            try await eventually("\(phone.name) sees three") { await phone.lifecycle.interaction(id)?.proposal?.participants.count == 3 }
        }
        await world.expectCleanLifecycles()
    }

    @Test func aRosterNamingSomeoneTheOwnerDidNotAskIsRefused() async throws {
        let world = World(1)
        try await world.start()
        defer { Task { await world.stop() } }
        let b = world["A"]
        let mallory = try Mallory(hub: world.hub)
        try await mallory.start()
        defer { Task { await mallory.stop() } }
        let mine = try await b.down(for: ["boba"], time: [T.slot(19, 21)], with: [], extraParticipants: [mallory.id])
        let conversation = try await mallory.findSharedTime(with: b.id)
        try await mallory.send(.query(try Query(issue: .activity, candidates: .keywords([T.keyword("boba")]))), to: b.id, in: conversation)
        _ = try await mallory.next(.answer, in: conversation)

        let stranger = PeerID.random()
        let terms = try Terms([
            .time: .slots([T.slot(19.5, 20.5)]), .activity: .keywords([T.keyword("boba")]), .people: .peers([mallory.id, b.id, stranger]),
        ])
        try await mallory.send(.propose(try Proposal(round: 0, terms: terms)), to: b.id, in: conversation)
        let no = try await mallory.next(.reject, in: conversation)
        // An ordinary no (ADR 0019 decision 5), and no card.
        #expect(no.body == .reject(Rejection(proposal: (no.body.rejection?.proposal)!, reason: .noOverlap)))
        #expect(await !b.lifecycle.reached(.proposed, mine))
    }

    // MARK: Invite mode

    @Test func anInvitationBecomesACardAndAPlan() async throws {
        let world = World(2)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        // B has no request of its own: an invitation is meant to be seen.
        let mine = try await a.down(for: ["boba"], time: [T.slot(20, 23)], with: [b], mode: .invite)
        try await eventually("B's invitation") { await !b.lifecycle.invitations.isEmpty }
        let theirs = try #require(await b.lifecycle.invitations.first)
        try await b.waitForProposal(theirs)
        let card = try #require(await b.lifecycle.interaction(theirs)?.proposal)
        #expect(card.participants == [a.id, b.id])
        #expect(card.terms[.time] == .slots([T.slot(20, 22)]))
        #expect(card.terms[.activity] == .keywords([T.keyword("boba")]))
        #expect(await b.lifecycle.interaction(theirs)?.role == .invitee)

        try await b.imIn(theirs)
        // Everyone invited answered, so A need not wait for the window.
        try await a.waitForProposal(mine)
        #expect(await a.lifecycle.interaction(mine)?.proposal?.participants == [a.id, b.id])
        try await a.imIn(mine)
        try await a.waitFor(.planned, mine)
        try await b.waitFor(.planned, theirs)
        #expect(await a.lifecycle.interaction(mine)?.plan?.time == (await b.lifecycle.interaction(theirs))?.plan?.time)
        // Every envelope of the conversation, both ways, says invite.
        #expect(await world.wire.envelopes.allSatisfy { $0.mode == .invite })
        await world.expectCleanLifecycles()
    }

    @Test func anInvitationKeepsWhoeverSaidImIn() async throws {
        let world = World(3)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world["A"], world["B"], world["C"])
        let mine = try await a.down(for: ["boba"], with: [b, c], mode: .invite)
        try await eventually("both invited") {
            let invited = (await b.lifecycle.invitations, await c.lifecycle.invitations)
            return !invited.0.isEmpty && !invited.1.isEmpty
        }
        let theirs = try #require(await b.lifecycle.invitations.first)
        try await b.waitForProposal(theirs)
        try await b.imIn(theirs)
        // C looks away. At the window, A's card lists A and B only.
        try await a.waitForProposal(mine)
        #expect(await a.lifecycle.interaction(mine)?.proposal?.participants == [a.id, b.id])
        try await a.imIn(mine)
        try await b.waitFor(.planned, theirs)
        let cs = try #require(await c.lifecycle.invitations.first)
        try await c.waitFor(.ended(.nobodyUp), cs)
        await world.expectCleanLifecycles()
    }

    @Test func aQuietAskNeverBecomesACard() async throws {
        let world = World(1)
        try await world.start()
        defer { Task { await world.stop() } }
        let b = world["A"]
        let mallory = try Mallory(hub: world.hub)
        try await mallory.start()
        defer { Task { await mallory.stop() } }
        let offer = try Terms([.time: .slots([T.slot(20, 21)]), .activity: .keywords([T.keyword("boba")])])
        // A proposal sent as a quiet ask, with no run behind it, and a PSI
        // step sent as an invitation: neither opens anything.
        try await mallory.send(.propose(try Proposal(round: 0, terms: offer)), to: b.id, in: ConversationID(), mode: .askQuietly)
        _ = try await b.down(for: ["boba"], with: [], extraParticipants: [mallory.id])
        let tokens = SlotTokenSet(namespace: DownForProfile.namespace, constraints: .empty, now: T.now, expiresAt: T.at(31), timeZone: T.utc)
        let session = try InsecurePSIStub().makeSession(role: .initiator, localSet: tokens.elements, configuration: SlotTokenSet.psiConfiguration())
        guard case .send(let payload) = try await session.start() else { return }
        let conversation = ConversationID()
        try await mallory.send(.psi(try PSIFrame(session: UUID(), step: 0, payload: payload)), to: b.id, in: conversation, mode: .invite)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await b.lifecycle.invitations.isEmpty)
        #expect(await mallory.inbox.envelopes.filter { $0.conversation == conversation }.isEmpty)
    }

    // MARK: Undetectable exclusion (ADR 0020 decision 9.2)

    @Test func aQuietAskFromOutsideTheAudienceGetsWhatNotDownGets() async throws {
        // B is down, but only with C. A quiet ask from A gets the same as
        // asking a friend who is not down: nothing, ever.
        let excluded = try await Self.repliesToAQuietAsk(bHasARequestExcludingA: true)
        let notDown = try await Self.repliesToAQuietAsk(bHasARequestExcludingA: false)
        #expect(excluded == notDown)
        #expect(excluded.isEmpty)
    }

    static func repliesToAQuietAsk(bHasARequestExcludingA: Bool) async throws -> [MessageBody.Kind] {
        let world = World(1)
        try await world.start()
        defer { Task { await world.stop() } }
        let b = world["A"]
        let mallory = try Mallory(hub: world.hub)
        try await mallory.start()
        defer { Task { await mallory.stop() } }
        if bHasARequestExcludingA { _ = try await b.down(for: ["boba"], with: [], extraParticipants: [PeerID.random()]) }
        for _ in 0..<3 { _ = try await mallory.startRun(with: b.id) }
        try await Task.sleep(for: .milliseconds(400))
        return await mallory.inbox.envelopes.map(\.body.kind)
    }

    // MARK: Yes or no, interactions, and budget (ADR 0019)

    @Test func everySendNamesItsInteractionAndAnswersNameTheirQuery() async throws {
        let policy = FixedPolicyEngine(.allow)
        let world = World(2, policy: policy)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        let mine = try await a.down(for: ["boba"], with: [b], budget: 15)
        let theirs = try await b.down(for: ["boba"], with: [a], budget: 30)
        try await a.waitForProposal(mine)
        try await b.waitForProposal(theirs)
        try await a.imIn(mine)
        try await b.imIn(theirs)
        try await a.waitFor(.planned, mine)

        let messages = await policy.evaluated
        for message in messages {
            let expected = message.envelope.sender == a.id ? mine : theirs
            #expect(message.context.interaction == expected)
        }
        // Each "I'm in" names the proposal it accepts as offered (ADR 0019
        // amendment 10); a starter's confirmation accepts no proposal.
        for message in messages {
            guard case .accept(let acceptance) = message.envelope.body else { continue }
            if message.envelope.sender == b.id {
                #expect(message.context.accepting?.isAcceptedAsOffered(by: acceptance) == true)
            } else {
                #expect(message.context.accepting == nil)
            }
        }
        let answers = messages.filter { $0.envelope.body.kind == .answer }
        #expect(!answers.isEmpty)
        for message in answers {
            guard case .answer(let answer) = message.envelope.body else { continue }
            #expect(message.context.answering?.isAnsweredYesOrNo(by: answer) == true)
        }
        // The owners' budgets stayed on their phones.
        for envelope in await world.wire.envelopes {
            switch envelope.body {
            case .query(let query): #expect(query.issue != .budget)
            case .propose(let proposal): #expect(proposal.terms[.budget] == nil)
            case .accept(let acceptance): #expect(acceptance.terms[.budget] == nil)
            default: break
            }
        }
        await world.expectCleanLifecycles()
    }

    // MARK: Restarts (ADR 0011, amendment 15)

    @Test func anEndedInvitationStaysEndedAfterARestart() async throws {
        let world = World(2)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        _ = try await a.down(for: ["boba"], with: [b], mode: .invite)
        try await eventually("B's invitation") { await !b.lifecycle.invitations.isEmpty }
        let theirs = try #require(await b.lifecycle.invitations.first)
        try await b.waitForProposal(theirs)
        try await b.service.answer(theirs, with: .pass)
        try await b.waitFor(.ended(.declined), theirs)
        let ended = try #require(await b.lifecycle.interaction(theirs))

        // B restarts and is told about the card that ended; A keeps
        // resending the invitation, which must not open a second card.
        let restarted = Phone(
            name: "B2", id: b.id, hub: world.hub, model: ScriptedAgentModel(), policy: FixedPolicyEngine(.allow),
            consent: ScriptedConsentProvider(.approved), psi: InsecurePSIStub(), clock: testClock(), configuration: fastConfiguration, ledger: b.ledger
        )
        await b.stop()
        try await restarted.start()
        defer { Task { await restarted.stop() } }
        await restarted.service.restore([ended])
        await restarted.service.handle(.peerAvailable(a.id))
        try await Task.sleep(for: .milliseconds(500))
        #expect(await restarted.lifecycle.invitations.isEmpty)
    }
}

extension MessageBody {
    var rejection: Rejection? { if case .reject(let rejection) = self { rejection } else { nil } }
}
