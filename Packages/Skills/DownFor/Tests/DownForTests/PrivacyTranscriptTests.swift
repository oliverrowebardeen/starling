import Foundation
@testable import DownFor
import StarlingCore
import StarlingFakes
import StarlingNegotiation
import Testing

/// Adversarial transcripts for the final-round review of PR #56: what a
/// hostile or curious starter can learn from what crosses the wire.
@Suite(.timeLimit(.minutes(1))) struct PrivacyTranscriptTests {
    // MARK: Finding 1: a card waiting on its owner says nothing

    @Test func aPassAndAnUnansweredCardAnswerProbesAlike() async throws {
        let passed = try await Self.probesAfterTheCard(pass: true)
        let silent = try await Self.probesAfterTheCard(pass: false)
        #expect(passed == silent)
        #expect(passed.isEmpty, "B answered a probe: \(passed)")
    }

    /// Mallory starts a quiet group with B, gets B's card on screen, then
    /// (after B passes, or while B has not answered) resends the earlier
    /// activity query and PSI step in fresh envelopes, starts an audience
    /// check, sends a plan B must refuse, and asks again in a fresh
    /// conversation. Returns everything B sent Mallory after the card.
    static func probesAfterTheCard(pass: Bool) async throws -> [MessageBody.Kind] {
        let world = World(1)
        try await world.start()
        defer { Task { await world.stop() } }
        let b = world["A"]
        let mallory = try Mallory(hub: world.hub)
        try await mallory.start()
        defer { Task { await mallory.stop() } }
        let mine = try await b.down(for: ["boba"], time: [T.slot(19, 21)], with: [], extraParticipants: [mallory.id])

        let (conversation, firstStep) = try await mallory.openRun(with: b.id)
        let query = try Query(issue: .activity, candidates: .keywords([T.keyword("boba")]))
        try await mallory.send(.query(query), to: b.id, in: conversation)
        _ = try await mallory.next(.answer, in: conversation)
        let plan = try Terms([.time: .slots([T.slot(19.5, 20.5)]), .activity: .keywords([T.keyword("boba")])])
        try await mallory.send(.propose(try Proposal(round: 0, terms: plan)), to: b.id, in: conversation)
        try await b.waitForProposal(mine)
        if pass {
            try await b.service.answer(mine, with: .pass)
            try await b.waitFor(.ended(.declined), mine)
        }
        let before = await mallory.inbox.envelopes.count

        try await mallory.send(.query(query), to: b.id, in: conversation)
        try await mallory.send(.psi(firstStep), to: b.id, in: conversation)
        let vetting = FriendTokens([PeerID.random()], size: FriendTokens.starterSetSize)
        let session = try InsecurePSIStub().makeSession(role: .initiator, localSet: vetting.elements, configuration: FriendTokens.starterConfiguration())
        if case .send(let payload) = try await session.start() {
            try await mallory.send(.psi(try PSIFrame(session: UUID(), step: DownForService.vettingStep, payload: payload)), to: b.id, in: conversation)
        }
        let late = try Terms([.time: .slots([T.slot(22, 23)]), .activity: .keywords([T.keyword("boba")])])
        try await mallory.send(.propose(try Proposal(round: 1, terms: late)), to: b.id, in: conversation)
        _ = try await mallory.openRun(with: b.id, awaitingReply: false)
        try await Task.sleep(for: .milliseconds(400))
        return await mallory.inbox.envelopes.dropFirst(before).map(\.body.kind)
    }

    // MARK: Finding 2: what B hears does not depend on C

    @Test func whatAMemberHearsIsTheSameWithOrWithoutAnotherInterestedFriend() async throws {
        let with = try await Self.membersTranscript(otherFriendIsUp: true)
        let without = try await Self.membersTranscript(otherFriendIsUp: false)
        #expect(with.kinds == without.kinds, "with C \(with.kinds), without \(without.kinds)")
        #expect(with.checks == 1 && without.checks == 1)
        // The proposal reaches B on the same fixed schedule.
        let gap = abs((with.proposedAt - without.proposedAt) / .milliseconds(1))
        #expect(gap < 250, "proposal time differs by \(gap) ms")
    }

    struct Transcript: Sendable {
        /// Kinds A sent B, repeats of the same kind collapsed (retries).
        let kinds: [MessageBody.Kind]
        /// Audience checks A started with B.
        let checks: Int
        /// When A's proposal reached B, after A took the request on.
        let proposedAt: Duration
    }

    /// A asks B and C; B asks only A; C, when up for it, asks only A. B
    /// and C did not ask each other, so the check excludes C, and B gets a
    /// plan for two either way.
    static func membersTranscript(otherFriendIsUp: Bool) async throws -> Transcript {
        let world = World(3)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world["A"], world["B"], world["C"])
        let clock = ContinuousClock()
        let started = clock.now
        _ = try await a.down(for: ["boba"], with: [b, c])
        let bs = try await b.down(for: ["boba"], with: [a])
        if otherFriendIsUp { _ = try await c.down(for: ["boba"], with: [a]) }
        try await b.waitForProposal(bs)
        let proposedAt = started.duration(to: clock.now)
        #expect(await b.lifecycle.interaction(bs)?.proposal?.participants == [a.id, b.id])
        let toB = await world.wire.envelopes.filter { $0.sender == a.id && $0.recipient == b.id }
        var kinds: [MessageBody.Kind] = []
        for kind in toB.map(\.body.kind) where kinds.last != kind { kinds.append(kind) }
        let firstPSI = toB.first { if case .psi = $0.body { true } else { false } }
        let checks = Set(toB.compactMap { envelope -> UUID? in
            guard case .psi(let frame) = envelope.body, case .psi(let first)? = firstPSI?.body, frame.session != first.session else { return nil }
            return frame.session
        }).count
        return Transcript(kinds: kinds, checks: checks, proposedAt: proposedAt)
    }

    // MARK: Finding 5 (lane part): a restart does not refill the run cap

    @Test func aRestartDoesNotRefillTheRunCap() async throws {
        let store = InMemoryDownForRequestStore()
        let world = World(1, stores: [store])
        try await world.start()
        defer { Task { await world.stop() } }
        let b = world["A"]
        let mallory = try Mallory(hub: world.hub)
        try await mallory.start()
        defer { Task { await mallory.stop() } }
        let mine = try await b.down(for: ["boba"], with: [], extraParticipants: [mallory.id])

        // Mallory spends B's whole run budget, in fresh conversations.
        var spent: Set<ConversationID> = []
        for _ in 0..<fastConfiguration.maxRunsPerPeer { spent.insert(try await mallory.openRun(with: b.id).0) }
        try await Task.sleep(for: .milliseconds(200))
        let saved = try #require(await b.lifecycle.interaction(mine))

        // B restarts; its request resumes from the store.
        let restarted = Phone(
            name: "B2", id: b.id, hub: world.hub, model: ScriptedAgentModel(), policy: FixedPolicyEngine(.allow),
            consent: ScriptedConsentProvider(.approved), psi: InsecurePSIStub(), clock: testClock(), configuration: fastConfiguration, store: store, ledger: b.ledger
        )
        await b.stop()
        await restarted.lifecycle.create(saved)
        try await restarted.start()
        defer { Task { await restarted.stop() } }
        await restarted.service.restore([saved])

        let (fresh, _) = try await mallory.openRun(with: b.id, awaitingReply: false)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await mallory.inbox.envelopes.filter { $0.conversation == fresh && $0.sender == b.id }.isEmpty)
        #expect(await mallory.inbox.envelopes.filter { spent.contains($0.conversation) && $0.body.kind == .psi }.count >= fastConfiguration.maxRunsPerPeer)
    }

    // MARK: Finding 3: an invitation is never matched quietly

    @Test func aQuietAskNeverConsumesAnInvitation() async throws {
        let world = World(1)
        try await world.start()
        defer { Task { await world.stop() } }
        let b = world["A"]
        let mallory = try Mallory(hub: world.hub)
        try await mallory.start()
        defer { Task { await mallory.stop() } }

        // B invites Mallory (B's own request, in Invite mode) and Mallory
        // invites B (an invitee card on B). Then Mallory asks quietly.
        let mine = try await b.down(for: ["boba"], time: [T.slot(19, 21)], with: [], extraParticipants: [mallory.id], mode: .invite)
        _ = try await mallory.next(.propose)
        let offer = try Terms([.time: .slots([T.slot(19.5, 20.5)]), .activity: .keywords([T.keyword("boba")])])
        try await mallory.send(.propose(try Proposal(round: 0, terms: offer)), to: b.id, in: ConversationID(), mode: .invite)
        try await eventually("B's invitation card") { await !b.lifecycle.invitations.isEmpty }
        let card = try #require(await b.lifecycle.invitations.first)
        try await b.waitForProposal(card)

        let (quiet, _) = try await mallory.openRun(with: b.id, awaitingReply: false)
        try await Task.sleep(for: .milliseconds(400))
        // No reply to the quiet ask, and both requests are as they were.
        #expect(await mallory.inbox.envelopes.filter { $0.conversation == quiet }.isEmpty)
        #expect(await b.lifecycle.state(card) == .proposed)
        #expect(await b.lifecycle.state(mine) == .negotiating)
        #expect(await b.service.requests[mine]?.engagement == .hub)
        #expect(await b.service.requests[card]?.engagement != .hub)
        await world.expectCleanLifecycles()
    }

    // MARK: Final privacy review, finding 1: a starter's pass looks like silence

    @Test func aStartersPassAndSilenceLookAlikeToAFriend() async throws {
        let passed = try await Self.proposalsSeenByAFriend(starterPasses: true)
        let silent = try await Self.proposalsSeenByAFriend(starterPasses: false)
        #expect(passed.kinds == [.propose] && silent.kinds == [.propose], "passed \(passed.kinds), silent \(silent.kinds)")
        // The same fixed schedule: as many resends, ending at the same time.
        #expect(abs(passed.count - silent.count) <= 1, "passed \(passed.count), silent \(silent.count)")
        #expect(passed.count > 3)
        let gap = abs((passed.lastAfterFirst - silent.lastAfterFirst) / .milliseconds(1))
        #expect(gap < 250, "the last proposal differs by \(gap) ms")
    }

    struct Delivered: Sendable {
        /// Kinds the starter sent after its proposal, repeats collapsed.
        let kinds: [MessageBody.Kind]
        let count: Int
        let lastAfterFirst: Duration
    }

    /// A and B ask each other; A carries the pair. Neither card is
    /// answered by B; A passes soon after its card shows, or never answers.
    /// Returns what A sent B from its first proposal until well after the
    /// owner window, timed as B received it.
    static func proposalsSeenByAFriend(starterPasses: Bool) async throws -> Delivered {
        let world = World(2)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        let mine = try await a.down(for: ["boba"], with: [b])
        let theirs = try await b.down(for: ["boba"], with: [a])
        try await a.waitForProposal(mine)
        try await b.waitForProposal(theirs)
        let clock = ContinuousClock()
        var seen: [(MessageBody.Kind, ContinuousClock.Instant)] = []
        var counted = 0
        func observe() async {
            let toB = await world.wire.envelopes.filter { $0.sender == a.id && $0.recipient == b.id }
            let proposalsSoFar = toB.drop { $0.body.kind != .propose }
            for envelope in proposalsSoFar.dropFirst(counted) { seen.append((envelope.body.kind, clock.now)) }
            counted = proposalsSoFar.count
        }
        await observe()
        if starterPasses {
            try await Task.sleep(for: .milliseconds(150))
            try await a.service.answer(mine, with: .pass)
        }
        // The window is 2 s; watch for a second more.
        let until = clock.now.advanced(by: .seconds(3))
        while clock.now < until {
            await observe()
            try await Task.sleep(for: .milliseconds(5))
        }
        try await a.waitFor(starterPasses ? .ended(.declined) : .ended(.expired), mine)
        #expect(await !b.lifecycle.reached(.planned, theirs))
        var kinds: [MessageBody.Kind] = []
        for (kind, _) in seen where kinds.last != kind { kinds.append(kind) }
        let first = try #require(seen.first?.1)
        let last = try #require(seen.last?.1)
        return Delivered(kinds: kinds, count: seen.count, lastAfterFirst: first.duration(to: last))
    }
}

extension Mallory {
    /// Opens a quiet run over the evening in a fresh conversation, and
    /// returns the conversation and the first PSI step, to resend later.
    func openRun(with peer: PeerID, awaitingReply: Bool = true) async throws -> (ConversationID, PSIFrame) {
        let tokens = SlotTokenSet(namespace: DownForProfile.namespace, constraints: .empty, now: T.now, expiresAt: T.at(31), timeZone: T.utc)
        let session = try InsecurePSIStub().makeSession(role: .initiator, localSet: tokens.elements, configuration: SlotTokenSet.psiConfiguration())
        guard case .send(let payload) = try await session.start() else { throw ValidationError("Mallory", "no first step") }
        let conversation = ConversationID()
        let frame = try PSIFrame(session: UUID(), step: 0, payload: payload)
        try await send(.psi(frame), to: peer, in: conversation)
        if awaitingReply, let reply = try? await next(.psi, in: conversation), case .psi(let step) = reply.body { _ = try? await session.handle(step.payload) }
        return (conversation, frame)
    }
}
