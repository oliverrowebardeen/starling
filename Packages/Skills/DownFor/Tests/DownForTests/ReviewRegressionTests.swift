import Foundation
@testable import DownFor
import StarlingCore
import StarlingFakes
import StarlingNegotiation
import Testing

/// One test per finding of the adversarial review of PR #56.
@Suite(.timeLimit(.minutes(1))) struct ReviewRegressionTests {
    /// Finding 2: a plan's cached confirmation never leaves once the
    /// request is withdrawn.
    @Test func aWithdrawnPlanReplaysNothing() async throws {
        let world = World(2)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        let mine = try await a.down(for: ["boba"], with: [b])
        let theirs = try await b.down(for: ["boba"], with: [a])
        try await a.waitForProposal(mine)
        try await b.waitForProposal(theirs)
        try await b.imIn(theirs)
        try await Task.sleep(for: .milliseconds(100))

        // A confirms while B cannot hear it, then withdraws the plan.
        await world.hub.partition(a.id, b.id)
        try await a.imIn(mine)
        try await a.waitFor(.planned, mine)
        await a.service.withdraw(mine)
        try await a.waitFor(.ended(.withdrawn), mine)
        let before = await world.wire.sent(by: a.id).count
        await world.hub.heal(a.id, b.id)

        // B keeps asking; A says nothing, so B never has a plan.
        try await Task.sleep(for: .milliseconds(800))
        #expect(await world.wire.sent(by: a.id).count == before)
        #expect(await !b.lifecycle.reached(.planned, theirs))
        await world.expectCleanLifecycles()
    }

    /// Finding 3: a friend starting fresh conversations cannot get past the
    /// run cap.
    @Test func freshConversationsCannotProbePastTheRunCap() async throws {
        let world = World(1)
        try await world.start()
        defer { Task { await world.stop() } }
        let b = world["A"]
        let mallory = try Mallory(hub: world.hub)
        try await mallory.start()
        defer { Task { await mallory.stop() } }
        _ = try await b.down(for: ["boba"], time: [T.slot(19, 21)], with: [], extraParticipants: [mallory.id])

        var started: Set<ConversationID> = []
        for _ in 0..<(fastConfiguration.maxRunsPerPeer + 3) {
            if let conversation = try? await mallory.startRun(with: b.id) { started.insert(conversation) }
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(300))
        // B's own run toward Mallory gives way to Mallory's first, and is
        // the only run handed back to the cap.
        let answered = Set(await mallory.inbox.envelopes.filter { $0.body.kind == .psi && started.contains($0.conversation) }.map(\.conversation))
        #expect(answered.count == fastConfiguration.maxRunsPerPeer, "answered \(answered.count)")
    }

    /// Finding 5: an older round in a fresh envelope never replaces the
    /// card, and a confirmation must name the proposal the owner accepted.
    @Test func anOldRoundNeverReplacesTheCard() async throws {
        let world = World(1)
        try await world.start()
        defer { Task { await world.stop() } }
        let b = world["A"]
        let mallory = try Mallory(hub: world.hub)
        try await mallory.start()
        defer { Task { await mallory.stop() } }
        let mine = try await b.down(for: ["boba", "tacos"], time: [T.slot(19, 21)], with: [], extraParticipants: [mallory.id])

        let conversation = try await mallory.findSharedTime(with: b.id)
        try await mallory.send(.query(try Query(issue: .activity, candidates: .keywords([T.keyword("boba"), T.keyword("tacos")]))), to: b.id, in: conversation)
        _ = try await mallory.next(.answer, in: conversation)

        let newer = try Terms([.time: .slots([T.slot(20, 21)]), .activity: .keywords([T.keyword("tacos")])])
        let older = try Terms([.time: .slots([T.slot(19.5, 20.5)]), .activity: .keywords([T.keyword("boba")])])
        let offer = try await mallory.send(.propose(try Proposal(round: 1, terms: newer)), to: b.id, in: conversation)
        try await b.waitForProposal(mine)
        try await mallory.send(.propose(try Proposal(round: 0, terms: older)), to: b.id, in: conversation)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await b.lifecycle.interaction(mine)?.proposal?.terms == newer)
        #expect(await b.lifecycle.interaction(mine)?.proposalRevision == 1)

        try await b.imIn(mine)
        _ = try await mallory.next(.accept, in: conversation)
        // A confirmation naming some other proposal is ignored.
        try await mallory.send(.accept(Acceptance(proposal: MessageID(), terms: newer)), to: b.id, in: conversation)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await b.lifecycle.state(mine) == .confirmed)
        try await mallory.send(.accept(Acceptance(proposal: offer.id, terms: newer)), to: b.id, in: conversation)
        try await b.waitFor(.planned, mine)
        await world.expectCleanLifecycles()
    }

    /// Finding 6: the coordinator applies planEnded; the service never
    /// reports it, even after the plan's time is over.
    @Test func theServiceNeverReportsPlanEnded() async throws {
        // The plan (20:00 to 22:00, an hour's notice after 19:00) ends and
        // its 30 minutes of grace pass in 1.3 s.
        let world = World(2, clock: testClock(speedup: 10_000))
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        let mine = try await a.down(for: ["boba"], with: [b])
        let theirs = try await b.down(for: ["boba"], with: [a])
        try await a.waitForProposal(mine)
        try await b.waitForProposal(theirs)
        try await a.imIn(mine)
        try await b.imIn(theirs)
        try await a.waitFor(.planned, mine)
        try await Task.sleep(for: .milliseconds(1_700))
        #expect(await !a.lifecycle.lifecycleEvents.contains(.planEnded))
        #expect(await a.lifecycle.state(mine) == .planned)
        // Its request is gone from the service by now, quietly.
        #expect(await a.service.requests[mine] == nil)
        await world.expectCleanLifecycles()
    }
}

extension Mallory {
    /// Opens a fresh conversation with a PSI request over the evening.
    func startRun(with peer: PeerID) async throws -> ConversationID {
        let tokens = SlotTokenSet(namespace: DownForProfile.namespace, constraints: .empty, now: T.now, expiresAt: T.at(31), timeZone: T.utc)
        let session = try InsecurePSIStub().makeSession(role: .initiator, localSet: tokens.elements, configuration: SlotTokenSet.psiConfiguration())
        guard case .send(let payload) = try await session.start() else { throw ValidationError("Mallory", "no first step") }
        let conversation = ConversationID()
        try await send(.psi(try PSIFrame(session: UUID(), step: 0, payload: payload)), to: peer, in: conversation)
        return conversation
    }
}
