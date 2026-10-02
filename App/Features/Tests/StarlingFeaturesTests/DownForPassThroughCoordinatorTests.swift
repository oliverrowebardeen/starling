import DownFor
import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import StarlingNegotiation
import Testing

/// Lane B's follow-up to PR #56 (P15-B request 9): a starter's pass on a
/// Down for... card through the real `LifecycleCoordinator` and the real
/// `DownForService` (ADR 0011 amendment 16, ADR 0210 decision 13). The
/// friend's agent is played on the wire, so everything the starter sends
/// it is recorded as it leaves.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct DownForPassThroughCoordinatorTests {
    /// The owner passes on the card, or never answers it. Either way the
    /// friend gets the same proposals on the same schedule. A pass hides
    /// the card at once, changes and retires nothing until the window, and
    /// only then ends as passed, when silence ends as expired.
    @Test func aStartersPassLooksLikeSilenceToTheFriend() async throws {
        let passed = try await Self.starter(passes: true)
        let silent = try await Self.starter(passes: false)

        #expect(passed.kinds == [.propose] && silent.kinds == [.propose], "passed \(passed.kinds), silent \(silent.kinds)")
        #expect(abs(passed.proposals - silent.proposals) <= 1, "passed \(passed.proposals), silent \(silent.proposals)")
        #expect(passed.proposals > 3)
        let gap = abs((passed.lastProposalAfterCard - silent.lastProposalAfterCard) / .milliseconds(1))
        #expect(gap < 250, "the last proposal differs by \(gap) ms")

        #expect(passed.hiddenAtOnce && passed.unchangedAfterPass && !passed.retiredBeforeEnd)
        #expect(passed.ending == .ended(.declined) && silent.ending == .ended(.expired))
        #expect(passed.endedAfterCard >= Self.window - .milliseconds(200) && silent.endedAfterCard >= Self.window - .milliseconds(200))
        #expect(passed.retiredAtEnd && silent.retiredAtEnd)
        #expect(!passed.stillHidden)
    }

    struct Outcome {
        /// Kinds the starter sent after its proposal, repeats collapsed.
        let kinds: [MessageBody.Kind]
        let proposals: Int
        let lastProposalAfterCard: Duration
        let hiddenAtOnce: Bool
        let unchangedAfterPass: Bool
        let retiredBeforeEnd: Bool
        let ending: InteractionState?
        let endedAfterCard: Duration
        let retiredAtEnd: Bool
        let stillHidden: Bool
    }

    static let window = Duration.seconds(2)

    static func starter(passes: Bool) async throws -> Outcome {
        // The starter's PeerID is the lowest, so it carries the pair.
        let me = try PeerID(bytes: Data(repeating: 0, count: 32))
        let friend = PeerID.random()
        let transport = RecordingTransport(localPeer: me)
        let ledger = InMemoryConversationLedger()
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved), ledger: ledger)
        let configuration = DownForConfiguration(retryInterval: .milliseconds(20), maxAttempts: 100, ownerWindow: window, maxBackoff: .milliseconds(200))
        let service = DownForService(
            localPeer: me, outbox: outbox, model: ScriptedAgentModel(), psi: InsecurePSIStub(), ledger: ledger,
            clock: SkillClock(now: { Evening.now }, sleep: { try await Task.sleep(for: $0) }), timeZone: Evening.utc, configuration: configuration
        )
        let coordinator = LifecycleCoordinator(registry: try SkillRegistry([DownFor.descriptor]), services: [service], store: InMemoryInteractionStore(), now: { Evening.now })
        await coordinator.start()
        await service.handle(.peerAvailable(friend))

        let boba = try Keyword("boba")
        let rules = OwnerRules(constraints: try ConstraintSet([
            .time: [try Constraint(.within([try TimeSlot(start: Evening.at(19.5), end: Evening.at(21))]))],
            .activity: [try Constraint(.prefers(liked: [boba], avoided: []), strength: .soft)],
        ]))
        let conversation = ConversationID()
        let request = SkillRequest(
            interaction: InteractionID(), conversation: conversation,
            intent: SkillIntent(skill: DownFor.ref, rules: rules, audience: .picked([friend]), mode: .askQuietly, expiresAt: Timestamp(Evening.at(24))),
            participants: [friend]
        )
        let id = try await coordinator.start(request, settings: SkillSettings(flags: .phase1_5))

        // The friend's agent: answers the time check and the activity query.
        let wire = FriendOnTheWire(me: me, friend: friend, transport: transport, service: service, conversation: conversation)
        try await wire.answerUntilProposed(liking: boba)
        await eventually { coordinator.interaction(id)?.state == .proposed }
        #expect(coordinator.interaction(id)?.state == .proposed)
        let clock = ContinuousClock()
        let cardShown = clock.now
        // Counted from the first proposal, as the card shows.
        let firstProposal = await wire.sentKinds().firstIndex(of: .propose) ?? 0

        var hiddenAtOnce = false
        var unchangedAfterPass = false
        var retiredBeforeEnd = false
        if passes {
            #expect(await coordinator.answer(id, with: .pass))
            hiddenAtOnce = coordinator.passed.contains(id)
            try await Task.sleep(for: .milliseconds(500))
            unchangedAfterPass = coordinator.interaction(id)?.state == .proposed
            retiredBeforeEnd = (try? await ledger.isRetired(conversation)) ?? true
        }

        // Watch what leaves for the friend until the request ends.
        var arrivals: [(MessageBody.Kind, ContinuousClock.Instant)] = []
        var seen = firstProposal
        let deadline = clock.now.advanced(by: window + .seconds(2))
        func observe() async {
            // One read per look, so nothing that arrives in between is lost.
            let kinds = await wire.sentKinds()
            for kind in kinds.dropFirst(seen) { arrivals.append((kind, clock.now)) }
            seen = kinds.count
        }
        while clock.now < deadline, coordinator.interaction(id)?.state.isFinal != true {
            await observe()
            try await Task.sleep(for: .milliseconds(5))
        }
        let endedAfterCard = cardShown.duration(to: clock.now)
        await observe()

        var kinds: [MessageBody.Kind] = []
        for (kind, _) in arrivals where kinds.last != kind { kinds.append(kind) }
        let last = arrivals.last { $0.0 == .propose }?.1 ?? cardShown
        return Outcome(
            kinds: kinds, proposals: arrivals.filter { $0.0 == .propose }.count, lastProposalAfterCard: cardShown.duration(to: last),
            hiddenAtOnce: hiddenAtOnce, unchangedAfterPass: unchangedAfterPass, retiredBeforeEnd: retiredBeforeEnd,
            ending: coordinator.interaction(id)?.state, endedAfterCard: endedAfterCard,
            retiredAtEnd: (try? await ledger.isRetired(conversation)) ?? false, stillHidden: coordinator.passed.contains(id)
        )
    }
}

/// 2026-10-02, with `now` at 19:00 UTC on a 30-minute boundary.
enum Evening {
    static let now = Date(timeIntervalSince1970: 1_790_967_600)
    static let utc = TimeZone(identifier: "UTC")!
    static func at(_ hour: Double) -> Date { now.addingTimeInterval((hour - 19) * 3600) }
}

/// Plays the friend's agent: reads what the starter sent from the recording
/// transport and answers into the starter's service, as its Inbox would.
actor FriendOnTheWire {
    let me: PeerID
    let friend: PeerID
    let transport: RecordingTransport
    let service: DownForService
    let conversation: ConversationID
    private var sequence: UInt64 = 0

    init(me: PeerID, friend: PeerID, transport: RecordingTransport, service: DownForService, conversation: ConversationID) {
        self.me = me
        self.friend = friend
        self.transport = transport
        self.service = service
        self.conversation = conversation
    }

    func sent() async -> [Envelope] {
        await transport.sent.filter { $0.peer == friend }.compactMap { try? EnvelopeCodec().decode($0.frame.bytes) }
    }

    func sentKinds() async -> [MessageBody.Kind] { await sent().map(\.body.kind) }

    private func next(_ kind: MessageBody.Kind) async throws -> Envelope {
        for _ in 0..<2000 {
            if let envelope = await sent().first(where: { $0.body.kind == kind }) { return envelope }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw ValidationError("FriendOnTheWire", "no \(kind.rawValue)")
    }

    private func reply(_ body: MessageBody) async throws {
        sequence += 1
        let envelope = try Envelope(
            conversation: conversation, sender: friend, recipient: me, sequence: sequence, sentAt: Timestamp(Evening.now),
            body: body, skill: DownFor.ref, mode: .askQuietly
        )
        await service.handle(.message(envelope))
    }

    /// Answers the starter's time check over the whole evening and says yes
    /// to `liked`, then waits for the proposal.
    func answerUntilProposed(liking liked: Keyword) async throws {
        let first = try await next(.psi)
        guard case .psi(let frame) = first.body else { return }
        let tokens = SlotTokenSet(
            namespace: "down_for/v1", constraints: .empty, now: Evening.now,
            expiresAt: Evening.at(24), timeZone: Evening.utc
        )
        let session = try InsecurePSIStub().makeSession(role: .responder, localSet: tokens.elements, configuration: SlotTokenSet.psiConfiguration())
        switch try await session.handle(frame.payload) {
        case .send(let payload), .finish(let payload?, _):
            try await reply(.psi(try PSIFrame(session: frame.session, step: frame.step + 1, payload: payload)))
        default:
            throw ValidationError("FriendOnTheWire", "no PSI reply")
        }
        let query = try await next(.query)
        try await reply(.answer(try Answer(query: query.id, issue: .activity, status: .answered, acceptable: .keywords([liked]))))
        _ = try await next(.propose)
    }
}
