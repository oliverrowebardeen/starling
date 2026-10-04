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

    /// Mallory starts a quiet ask with B, gets B's card on screen, then
    /// (after B passes, or while B has not answered) resends the earlier
    /// activity query and PSI step in fresh envelopes, sends a plan B must
    /// refuse, and asks again in a fresh conversation. Returns everything B sent Mallory after the card.
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
        let late = try Terms([.time: .slots([T.slot(22, 23)]), .activity: .keywords([T.keyword("boba")])])
        try await mallory.send(.propose(try Proposal(round: 1, terms: late)), to: b.id, in: conversation)
        _ = try await mallory.openRun(with: b.id, awaitingReply: false)
        try await Task.sleep(for: .milliseconds(400))
        return await mallory.inbox.envelopes.dropFirst(before).map(\.body.kind)
    }

    // MARK: One-to-one: what a friend hears never depends on another friend

    @Test func whatAMemberHearsIsTheSameWithOrWithoutAnotherInterestedFriend() async throws {
        let with = try await Self.membersTranscript(otherFriendIsUp: true)
        let without = try await Self.membersTranscript(otherFriendIsUp: false)
        #expect(with.kinds == without.kinds, "with C \(with.kinds), without \(without.kinds)")
        // No audience check, or anything else, about other friends.
        #expect(with.checks == 0 && without.checks == 0)
        // The same proposals at the same scheduled instants, on the
        // service's clock: compared exactly, whatever the machine's load.
        #expect(with.proposalsByInstant == without.proposalsByInstant)
        #expect(with.proposalsByInstant == Array(1...with.proposalsByInstant.count))
    }

    struct Transcript: Sendable {
        /// Kinds A sent B, repeats of the same kind collapsed (retries).
        let kinds: [MessageBody.Kind]
        /// PSI sessions A started with B beyond the first.
        let checks: Int
        /// Proposals B had from A by each instant of the delivery schedule.
        let proposalsByInstant: [Int]
    }

    /// A asks B and C, each on its own; B asks A; C, when up for it, asks
    /// A. Runs on virtual time.
    static func membersTranscript(otherFriendIsUp: Bool) async throws -> Transcript {
        let time = VirtualTime()
        let world = World(3, clock: time.clock(now: T.now))
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world["A"], world["B"], world["C"])
        _ = try await a.downEach(for: ["boba"], with: [b, c])
        let bs = try await b.down(for: ["boba"], with: [a])
        if otherFriendIsUp { _ = try await c.down(for: ["boba"], with: [a]) }
        try await b.waitForProposal(bs)
        #expect(await b.lifecycle.interaction(bs)?.proposal?.participants == [a.id, b.id])
        let proposalsByInstant = try await time.proposalsAtEachInstant {
            await world.wire.envelopes.filter { $0.sender == a.id && $0.recipient == b.id && $0.body.kind == .propose }.count
        }
        let toB = await world.wire.envelopes.filter { $0.sender == a.id && $0.recipient == b.id }
        var kinds: [MessageBody.Kind] = []
        for kind in toB.map(\.body.kind) where kinds.last != kind { kinds.append(kind) }
        let sessions = Set(toB.compactMap { envelope -> UUID? in if case .psi(let frame) = envelope.body { frame.session } else { nil } })
        return Transcript(kinds: kinds, checks: max(0, sessions.count - 1), proposalsByInstant: proposalsByInstant)
    }

    // MARK: Focused review of e60b3c0: a restart retires the starter's conversation

    /// B's card from Mallory shows; B passes, or never answers; then B's
    /// app is killed without a shutdown and restored. With a new request
    /// for Mallory open, Mallory sends a first PSI step in the old
    /// conversation. B answers neither way: the restored interaction
    /// retired the starter's conversation, as the pass did.
    @Test func aRestartRetiresTheStartersConversationAfterAPassOrSilence() async throws {
        let passed = try await Self.probeAfterARestart(passBeforeRestart: true)
        let silent = try await Self.probeAfterARestart(passBeforeRestart: false)
        #expect(passed == silent)
        #expect(passed.isEmpty, "B answered in the old conversation: \(passed)")
    }

    static func probeAfterARestart(passBeforeRestart: Bool) async throws -> [MessageBody.Kind] {
        let store = InMemoryDownForRequestStore()
        let world = World(1, stores: [store])
        try await world.start()
        defer { Task { await world.stop() } }
        let b = world["A"]
        let mallory = try Mallory(hub: world.hub)
        try await mallory.start()
        defer { Task { await mallory.stop() } }
        let mine = try await b.down(for: ["boba"], time: [T.slot(19, 21)], with: [], extraParticipants: [mallory.id])
        let (conversation, firstStep) = try await mallory.openRun(with: b.id)
        try await mallory.send(.query(try Query(issue: .activity, candidates: .keywords([T.keyword("boba")]))), to: b.id, in: conversation)
        _ = try await mallory.next(.answer, in: conversation)
        let plan = try Terms([.time: .slots([T.slot(19.5, 20.5)]), .activity: .keywords([T.keyword("boba")])])
        try await mallory.send(.propose(try Proposal(round: 0, terms: plan)), to: b.id, in: conversation)
        try await b.waitForProposal(mine)
        if passBeforeRestart {
            try await b.pass(mine)
            try await b.waitFor(.ended(.declined), mine)
        }
        let saved = try #require(await b.lifecycle.interaction(mine))

        // Killed, not shut down; then restored from the same stores.
        await b.crash()
        let restarted = Phone(
            name: "B2", id: b.id, hub: world.hub, model: ScriptedAgentModel(), policy: FixedPolicyEngine(.allow),
            consent: ScriptedConsentProvider(.approved), psi: InsecurePSIStub(), clock: testClock(), configuration: fastConfiguration,
            store: store, ledger: b.ledger
        )
        await restarted.lifecycle.create(saved)
        try await restarted.start()
        defer { Task { await restarted.stop() } }
        await restarted.service.restore([saved])
        if !passBeforeRestart { try await restarted.waitFor(.ended(.failed), mine) }

        // A new request for Mallory, then a probe in the old conversation.
        _ = try await restarted.down(for: ["boba"], time: [T.slot(19, 21)], with: [], extraParticipants: [mallory.id])
        let before = await mallory.inbox.envelopes.count
        try await mallory.send(.psi(firstStep), to: b.id, in: conversation)
        try await Task.sleep(for: .milliseconds(400))
        return await mallory.inbox.envelopes.dropFirst(before).filter { $0.conversation == conversation }.map(\.body.kind)
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
        // The same fixed schedule, instant by instant, on the service's clock.
        #expect(passed.proposalsByInstant == silent.proposalsByInstant)
        #expect(passed.proposalsByInstant == Array(1...passed.proposalsByInstant.count))
        #expect(passed.proposalsByInstant.count > 3)
    }

    struct Delivered: Sendable {
        /// Kinds the starter sent from its first proposal on, repeats collapsed.
        let kinds: [MessageBody.Kind]
        /// Proposals B had by each instant of the delivery schedule.
        let proposalsByInstant: [Int]
    }

    /// A and B ask each other; A carries the pair. B never answers its
    /// card; A passes as soon as its card shows, or never answers. Runs on
    /// virtual time through the schedule and the window.
    static func proposalsSeenByAFriend(starterPasses: Bool) async throws -> Delivered {
        let time = VirtualTime()
        let world = World(2, clock: time.clock(now: T.now))
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        let mine = try await a.down(for: ["boba"], with: [b])
        let theirs = try await b.down(for: ["boba"], with: [a])
        try await a.waitForProposal(mine)
        try await b.waitForProposal(theirs)
        if starterPasses { try await a.pass(mine) }
        let proposalsByInstant = try await time.proposalsAtEachInstant {
            await world.wire.envelopes.filter { $0.sender == a.id && $0.recipient == b.id && $0.body.kind == .propose }.count
        }
        try await time.waitForSleep(at: fastConfiguration.ownerWindow, "A's window")
        await time.advance(to: fastConfiguration.ownerWindow)
        try await a.waitFor(starterPasses ? .ended(.declined) : .ended(.expired), mine, timeout: .seconds(60))
        #expect(await !b.lifecycle.reached(.planned, theirs))
        let toB = await world.wire.envelopes.filter { $0.sender == a.id && $0.recipient == b.id }
        var kinds: [MessageBody.Kind] = []
        for kind in toB.map(\.body.kind).drop(while: { $0 != .propose }) where kinds.last != kind { kinds.append(kind) }
        return Delivered(kinds: kinds, proposalsByInstant: proposalsByInstant)
    }

    // MARK: Focused review of 1d52e7b: toggle another friend's interest

    /// A < B < C. A asks B and C, each on its own; C asks A and B. B either
    /// asks only A or has no request at all, and C never answers its card.
    /// Everything that reaches C is the same either way: the same kinds in
    /// the same order, the same plan, as many proposals, at the same times.
    @Test func whatCHearsDoesNotDependOnAnotherFriendsInterest() async throws {
        let bIsUp = try await Self.cTranscript(bIsUp: true)
        let bIsNot = try await Self.cTranscript(bIsUp: false)
        #expect(bIsUp.kinds == bIsNot.kinds, "B up \(bIsUp.kinds), B not \(bIsNot.kinds)")
        #expect(bIsUp.terms == bIsNot.terms && bIsUp.terms != nil)
        #expect(bIsUp.participants == ["A", "C"] && bIsNot.participants == ["A", "C"])
        #expect(!bIsUp.kinds.contains(.reject))
        // The same proposals at the same scheduled instants, compared
        // exactly on the service's clock.
        #expect(bIsUp.proposalsByInstant == bIsNot.proposalsByInstant)
        #expect(bIsUp.proposalsByInstant == Array(1...bIsUp.proposalsByInstant.count))
        // And nothing at all from B, either way.
        #expect(bIsUp.fromB.isEmpty && bIsNot.fromB.isEmpty)
    }

    struct CView: Sendable {
        let terms: Terms?
        let participants: [String]?
        /// Everything A sent C, repeats collapsed.
        let kinds: [MessageBody.Kind]
        /// Proposals C had from A by each instant of the delivery schedule.
        let proposalsByInstant: [Int]
        let fromB: [MessageBody.Kind]
    }

    /// Runs on virtual time.
    static func cTranscript(bIsUp: Bool) async throws -> CView {
        let time = VirtualTime()
        let world = World(3, clock: time.clock(now: T.now))
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world["A"], world["B"], world["C"])
        _ = try await a.downEach(for: ["boba"], with: [b, c])
        let cs = try await c.downEach(for: ["boba"], with: [a, b])
        if bIsUp { _ = try await b.down(for: ["boba"], with: [a]) }
        try await c.waitForProposal(cs[0])
        let proposalsByInstant = try await time.proposalsAtEachInstant {
            await world.wire.envelopes.filter { $0.sender == a.id && $0.recipient == c.id && $0.body.kind == .propose }.count
        }
        let toC = await world.wire.envelopes.filter { $0.sender == a.id && $0.recipient == c.id }
        var kinds: [MessageBody.Kind] = []
        for kind in toC.map(\.body.kind) where kinds.last != kind { kinds.append(kind) }
        let card = await c.lifecycle.interaction(cs[0])?.proposal
        let names = [a.id: "A", b.id: "B", c.id: "C"]
        return CView(
            terms: card?.terms, participants: card?.participants.map { names[$0] ?? "?" }, kinds: kinds, proposalsByInstant: proposalsByInstant,
            fromB: await world.wire.envelopes.filter { $0.sender == b.id && $0.recipient == c.id }.map(\.body.kind)
        )
    }

    // MARK: ADR 0011 amendment 16: a starter's pass goes through the skill

    /// The coordinator hides the card and calls the service; the service
    /// keeps the proposal on its schedule and reports the pass, and retires
    /// the conversation, only when that schedule and the window are over.
    @Test func aStartersPassEndsOnlyWhenItsScheduleDoes() async throws {
        let time = VirtualTime()
        let world = World(2, clock: time.clock(now: T.now))
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        let mine = try await a.down(for: ["boba"], with: [b])
        _ = try await b.down(for: ["boba"], with: [a])
        try await a.waitForProposal(mine)
        try await a.pass(mine)
        #expect(await a.lifecycle.hidden.contains(mine))
        let conversation = try #require(await a.lifecycle.interaction(mine)?.conversation)
        // The whole schedule goes out after the pass, as after silence.
        let proposalsByInstant = try await time.proposalsAtEachInstant {
            await world.wire.envelopes.filter { $0.sender == a.id && $0.body.kind == .propose }.count
        }
        #expect(proposalsByInstant == Array(1...proposalsByInstant.count))
        // Just before the window: not reported, not retired.
        try await time.waitForSleep(at: fastConfiguration.ownerWindow, "A's window")
        await time.advance(to: fastConfiguration.ownerWindow - .milliseconds(1))
        #expect(await a.lifecycle.state(mine) == .proposed)
        #expect(try await !a.ledger.isRetired(conversation))
        // At the window: the pass, with the conversation retired first.
        await time.advance(to: fastConfiguration.ownerWindow)
        try await a.waitFor(.ended(.declined), mine, timeout: .seconds(60))
        #expect(try await a.ledger.isRetired(conversation))
        await world.expectCleanLifecycles()
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
