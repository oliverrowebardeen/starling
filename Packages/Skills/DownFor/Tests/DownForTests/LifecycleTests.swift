import Foundation
@testable import DownFor
import StarlingCore
import StarlingFakes
import StarlingTransport
import StarlingNegotiation
import Synchronization
import Testing

/// Consent, restarts, deadlines, and lost messages, over LoopbackHub.
@Suite(.timeLimit(.minutes(1))) struct LifecycleTests {
    @Test func consentShowsOnTheLifecycleAndResumesTheStep() async throws {
        let consent = GatedConsent()
        let world = World(2, policy: consentForEverything(), consent: consent)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])

        let mine = try await a.down(for: ["boba"], with: [b])
        // A's first PSI step waits on its sheet: Needs you.
        try await eventually("A's sheet") { await a.lifecycle.state(mine) == .awaitingConsent(resume: .negotiating) }
        let theirs = try await b.down(for: ["boba"], with: [a])

        // Approve every sheet as it comes, until both cards show.
        try await eventually(timeout: .seconds(10), "both cards") {
            await consent.answerAll(.approved)
            let cards = (await a.lifecycle.state(mine), await b.lifecycle.state(theirs))
            return cards == (.proposed, .proposed)
        }
        try await a.imIn(mine)
        try await b.imIn(theirs)
        try await eventually(timeout: .seconds(10), "both planned") {
            await consent.answerAll(.approved)
            let planned = (await a.lifecycle.reached(.planned, mine), await b.lifecycle.reached(.planned, theirs))
            return planned == (true, true)
        }
        // Each sheet suspended exactly one step and was resumed by its own ID.
        let interaction = try #require(await a.lifecycle.interaction(mine))
        #expect(interaction.consentWatermark > 0)
        #expect(interaction.pendingConsents.isEmpty)
        await world.expectCleanLifecycles()
    }

    @Test func dontSendEndsTheRequestAndNothingLeaves() async throws {
        let consent = GatedConsent()
        let world = World(2, policy: consentForEverything(), consent: consent)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])

        let mine = try await a.down(for: ["boba"], with: [b])
        try await eventually("A's sheet") { await a.lifecycle.state(mine) == .awaitingConsent(resume: .negotiating) }
        await consent.answerAll(.declined)
        try await Task.sleep(for: .milliseconds(300))
        // The coordinator applies the pass; the service adds nothing and
        // sends nothing more, retries included.
        #expect(await a.lifecycle.state(mine) == .ended(.declined))
        #expect(await a.lifecycle.lifecycleEvents.isEmpty)
        #expect(await world.wire.sent(by: a.id).isEmpty)
        #expect(await consent.requests == 1)
        await world.expectCleanLifecycles()
    }

    @Test func withdrawingCancelsASendWaitingOnConsent() async throws {
        let consent = GatedConsent()
        let world = World(2, policy: consentForEverything(), consent: consent)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])

        let mine = try await a.down(for: ["boba"], with: [b])
        try await eventually("A's sheet") { await consent.pending == 1 }
        await a.service.withdraw(mine)
        try await a.waitFor(.ended(.withdrawn), mine)
        // The owner approves the old sheet afterwards: still nothing leaves.
        await consent.answerAll(.approved)
        try await Task.sleep(for: .milliseconds(300))
        await consent.answerAll(.approved)
        #expect(await world.wire.sent(by: a.id).isEmpty)
        await world.expectCleanLifecycles()
    }

    @Test func aDenialForAStepAlreadyReplacedIsDropped() async throws {
        let policy = HeldDenial()
        let world = World(3, policy: policy)
        let (a, b, c) = (world["A"], world["B"], world["C"])
        await policy.hold(groupProposalsTo: b.id)
        try await world.start()
        defer { Task { await world.stop() } }

        let ids = [
            try await a.down(for: ["boba"], with: [b, c]),
            try await b.down(for: ["boba"], with: [a, c]),
            try await c.down(for: ["boba"], with: [a, b]),
        ]
        // Revision 1 (all three) reaches C; the send to B waits in the policy.
        try await a.waitForProposal(ids[0])
        try await c.waitForProposal(ids[2])
        try await eventually("held") { await policy.held == 1 }
        // C's card now says it cannot run Down for... (an update, say): A
        // drops C at once and re-plans for two while the send of revision 1
        // is still in flight.
        let card = try AgentCard(model: .onDevice, capabilities: [], skills: [])
        await a.service.handle(.message(try Envelope(conversation: ConversationID(), sender: c.id, recipient: a.id, sequence: 0, sentAt: Timestamp(T.now), body: .hello(card))))
        try await a.waitForProposal(ids[0], revision: 2)

        // Now revision 1's send is denied: a superseded step says nothing.
        await policy.release()
        try await b.waitForProposal(ids[1])
        #expect(await b.lifecycle.interaction(ids[1])?.proposal?.participants == [a.id, b.id])
        try await a.imIn(ids[0])
        try await b.imIn(ids[1])
        try await a.waitFor(.planned, ids[0])
        #expect(await !a.lifecycle.reached(.ended(.blockedByPrivacy), ids[0]))
        await world.expectCleanLifecycles()
    }

    @Test func aDeniedImInBlocksTheRequestAtThatStep() async throws {
        let denier = Denier()
        let world = World(2, policy: FixedPolicyEngine { message in
            guard case .accept = message.envelope.body, denier.denies(message.envelope.sender) else { return .allow }
            return .deny(PolicyViolation(rule: "disclosure.never", issue: .budget))
        })
        let (a, b) = (world["A"], world["B"])
        denier.set(b.id)
        try await world.start()
        defer { Task { await world.stop() } }
        let mine = try await a.down(for: ["boba"], with: [b])
        let theirs = try await b.down(for: ["boba"], with: [a])
        try await b.waitForProposal(theirs)
        try await b.imIn(theirs)
        try await b.waitFor(.ended(.blockedByPrivacy), theirs)
        #expect(await b.lifecycle.reached(.confirmed, theirs))
        #expect(await !a.lifecycle.reached(.planned, mine))
        await world.expectCleanLifecycles()
    }

    @Test func aSendThePolicyRefusesBlocksTheRequest() async throws {
        let world = World(2, policy: FixedPolicyEngine(.deny(PolicyViolation(rule: "disclosure.never", issue: .time))))
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        let mine = try await a.down(for: ["boba"], with: [b])
        try await a.waitFor(.ended(.blockedByPrivacy), mine)
        #expect(await world.wire.sent(by: a.id).isEmpty)
        await world.expectCleanLifecycles()
    }

    @Test func aPeersMessageNeverStartsAnything() async throws {
        let world = World(2)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])

        // A asks, as a chained skill would, but B has no open request.
        _ = try await a.down(for: ["boba"], with: [b], chainedFrom: ConversationID())
        try await Task.sleep(for: .milliseconds(300))
        #expect(await b.lifecycle.events.isEmpty)
        #expect(await world.wire.sent(by: b.id).isEmpty)
        #expect(await b.service.diagnostics.modelCalls == 0)
    }

    @Test func aRequestResumesAfterARestart() async throws {
        let store = InMemoryDownForRequestStore()
        let world = World(2, stores: [store, InMemoryDownForRequestStore()])
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        let mine = try await a.down(for: ["boba"], with: [b])
        try await Task.sleep(for: .milliseconds(50))
        let saved = try #require(await a.lifecycle.interaction(mine))
        #expect(saved.state == .negotiating)

        // The app restarts: a new service on the same Outbox setup and store.
        let restarted = Phone(
            name: "A2", id: a.id, hub: world.hub, model: ScriptedAgentModel(), policy: FixedPolicyEngine(.allow),
            consent: ScriptedConsentProvider(.approved), psi: InsecurePSIStub(), clock: testClock(), configuration: fastConfiguration, store: store, ledger: a.ledger
        )
        await a.stop()
        await restarted.lifecycle.create(saved)
        try await restarted.start()
        defer { Task { await restarted.stop() } }
        await restarted.service.handle(.peerAvailable(b.id))
        await restarted.service.restore([saved])

        let theirs = try await b.down(for: ["boba"], with: [a])
        try await restarted.waitForProposal(mine)
        try await b.waitForProposal(theirs)
        try await restarted.imIn(mine)
        try await b.imIn(theirs)
        try await restarted.waitFor(.planned, mine)
        try await b.waitFor(.planned, theirs)
        #expect(await restarted.lifecycle.refused.isEmpty)
    }

    @Test func aCardOrSheetInFlightCannotSurviveARestart() async throws {
        let world = World(1)
        try await world.start()
        defer { Task { await world.stop() } }
        var proposed = Interaction(skill: DownFor.ref, role: .initiator, participants: [PeerID.random()], createdAt: Timestamp(T.now))
        try proposed.apply(.started, at: Timestamp(T.now))
        try proposed.apply(.consentNeeded(request: 1), at: Timestamp(T.now))
        let phone = world["A"]
        await phone.lifecycle.create(proposed)
        await phone.service.restore([proposed])
        try await phone.waitFor(.ended(.failed), proposed.id)
        await world.expectCleanLifecycles()
    }

    @Test func friendsWhoNeverAnswerAreLeftOutAfterTheWindow() async throws {
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
        try await a.imIn(ids[0])
        try await b.imIn(ids[1])
        // C looks away. After the 2 s window, A and B get a plan for two.
        // C hears nothing about it: whether A said I'm in is not C's to
        // learn (final privacy review), so C's card ends when its own wait
        // does.
        try await a.waitForProposal(ids[0], revision: 2)
        try await a.imIn(ids[0])
        try await b.waitForProposal(ids[1], revision: 2)
        try await b.imIn(ids[1])
        try await a.waitFor(.planned, ids[0])
        try await b.waitFor(.planned, ids[1])
        #expect(await a.lifecycle.interaction(ids[0])?.plan?.attendees.peers == [a.id, b.id])
        try await c.waitFor(.ended(.nobodyUp), ids[2])
        // (B's own group with C stood down for A's, and says so; A says
        // nothing.)
        #expect(await world.wire.envelopes.filter { $0.sender == a.id && $0.recipient == c.id && $0.body.kind == .reject }.isEmpty)
        await world.expectCleanLifecycles()
    }

    @Test func aLostConfirmationIsReplayed() async throws {
        let world = World(2)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        let mine = try await a.down(for: ["boba"], with: [b])
        let theirs = try await b.down(for: ["boba"], with: [a])
        try await a.waitForProposal(mine)
        try await b.waitForProposal(theirs)

        // Cut the link just as A confirms; B's accept keeps coming back.
        try await b.imIn(theirs)
        try await Task.sleep(for: .milliseconds(50))
        await world.hub.partition(a.id, b.id)
        try await a.imIn(mine)
        try await a.waitFor(.planned, mine)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await b.lifecycle.state(theirs) == .confirmed)
        await world.hub.heal(a.id, b.id)
        try await b.waitFor(.planned, theirs)
        await world.expectCleanLifecycles()
    }

    @Test func aHostileStarterNeverPutsABadPlanOnACard() async throws {
        let world = World(1)
        try await world.start()
        defer { Task { await world.stop() } }
        let b = world["A"]
        // Mallory is paired (in B's audience) and has the lowest ID, so B
        // answers Mallory's run. Mallory scripts every message by hand.
        let mallory = try Mallory(hub: world.hub)
        try await mallory.start()
        defer { Task { await mallory.stop() } }
        let mine = try await b.down(for: ["boba"], time: [T.slot(19, 21)], with: [], budget: 15, extraParticipants: [mallory.id])

        let conversation = try await mallory.findSharedTime(with: b.id)
        let query = try await mallory.send(.query(try Query(issue: .activity, candidates: .keywords([T.keyword("boba")]))), to: b.id, in: conversation)
        let answer = try await mallory.next(.answer, in: conversation)
        #expect(answer.body == .answer(try Answer(query: query.id, issue: .activity, status: .answered, acceptable: .keywords([T.keyword("boba")]))))

        // Over B's budget: no card, and B leaves Mallory's group.
        let greedy = try Terms([
            .time: .slots([T.slot(19.5, 20.5)]), .activity: .keywords([T.keyword("boba")]),
            .budget: .amount(T.usd(50)),
        ])
        try await mallory.send(.propose(try Proposal(round: 0, terms: greedy)), to: b.id, in: conversation)
        _ = try await mallory.next(.reject, in: conversation)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await !b.lifecycle.reached(.proposed, mine))
        #expect(await b.lifecycle.state(mine) == .negotiating)
        #expect(await b.service.diagnostics.gateRefusals == 0)
        await world.expectCleanLifecycles()
    }
}

/// A paired friend with no service: the test scripts every message. It has
/// an Outbox and an Inbox like any phone, so its frames are well formed;
/// only their content is hostile.
final class Mallory: Sendable {
    let id: PeerID
    let transport: LoopbackTransport
    let outbox: Outbox
    let inbox = Wire()
    private let loop = Synchronization.Mutex<Task<Void, Never>?>(nil)

    init(hub: LoopbackHub) throws {
        id = try PeerID(bytes: Data(repeating: 0, count: 32))
        transport = LoopbackTransport(localPeer: id, hub: hub)
        outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved))
    }

    func start() async throws {
        let events = Inbox(localPeer: id).events(from: transport)
        let inbox = inbox
        loop.withLock { $0 = Task { for await event in events { if case .message(let envelope) = event { await inbox.record(envelope) } } } }
        try await transport.start()
    }

    func stop() async {
        await transport.stop()
        loop.withLock { $0?.cancel() }
    }

    @discardableResult
    func send(_ body: MessageBody, to peer: PeerID, in conversation: ConversationID, mode: SendMode = .askQuietly) async throws -> Envelope {
        try await outbox.send(body, to: peer, conversation: conversation, skill: DownFor.ref, mode: mode)
    }

    func next(_ kind: MessageBody.Kind, in conversation: ConversationID? = nil) async throws -> Envelope {
        let matches: @Sendable (Envelope) -> Bool = { $0.body.kind == kind && (conversation == nil || $0.conversation == conversation) }
        try await eventually("a \(kind.rawValue)") { await self.inbox.envelopes.contains(where: matches) }
        return try #require(await inbox.envelopes.first(where: matches))
    }

    /// Runs PSI over every slot of the evening, as a starter.
    func findSharedTime(with peer: PeerID) async throws -> ConversationID {
        let tokens = SlotTokenSet(namespace: DownForProfile.namespace, constraints: .empty, now: T.now, expiresAt: T.at(31), timeZone: T.utc)
        let session = try InsecurePSIStub().makeSession(role: .initiator, localSet: tokens.elements, configuration: SlotTokenSet.psiConfiguration())
        guard case .send(let payload) = try await session.start() else { throw ValidationError("Mallory", "no first step") }
        let conversation = ConversationID()
        try await send(.psi(try PSIFrame(session: UUID(), step: 0, payload: payload)), to: peer, in: conversation)
        guard case .psi(let reply) = try await next(.psi, in: conversation).body else { throw ValidationError("Mallory", "no reply") }
        _ = try await session.handle(reply.payload)
        return conversation
    }
}

/// Holds every group proposal to one friend in the policy until released,
/// then denies it, as a privacy topic changed to Never would.
actor HeldDenial: PolicyEngine {
    private var target: PeerID?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var held = 0

    func hold(groupProposalsTo peer: PeerID) { target = peer }

    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        guard message.envelope.recipient == target, case .propose(let proposal) = message.envelope.body, proposal.terms[.people] != nil else { return .allow }
        held += 1
        if !released { await withCheckedContinuation { waiting.append($0) } }
        return .deny(PolicyViolation(rule: "disclosure.never", issue: .people))
    }
}

/// Picks, after the world exists, whose sends a policy denies.
final class Denier: Sendable {
    private let peer = Synchronization.Mutex<PeerID?>(nil)
    func set(_ id: PeerID) { peer.withLock { $0 = id } }
    func denies(_ id: PeerID) -> Bool { peer.withLock { $0 == id } }
}
