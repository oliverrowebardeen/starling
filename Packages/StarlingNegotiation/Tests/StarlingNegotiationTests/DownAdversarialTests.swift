import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingNegotiation
import StarlingTransport
import Testing

/// Hostile peers and a misbehaving model. The invariant under test: nothing
/// that breaks the owner's hard limits reaches the Outbox, and nothing
/// hostile produces a notification.
@Suite(.timeLimit(.minutes(1))) struct DownAdversarialTests {
    static let benRules = try! T.constraints(time: [T.slot(19, 22)], avoided: ["sushi"], maxBudget: 15)

    /// Ben (honest) plus Mallory, a paired friend who scripts her messages.
    /// Mallory is paired after Ben has seen her link come up and set his
    /// intent, so Ben never starts a run of his own with her and every Ben
    /// message on the wire is a reply.
    func benAndMallory() async throws -> (DownWorld, DownNode, RawPeer) {
        let world = DownWorld(["ben"])
        let mallory = RawPeer(hub: world.hub)
        try await world.start()
        try await mallory.start()
        let ben = world["ben"]
        try await eventually("ben sees mallory") { await ben.negotiator.isReachable(mallory.id) }
        try await ben.negotiator.setIntent(DownIntent(rules: OwnerRules(constraints: Self.benRules), level: .maybe, expiresAt: Timestamp(T.at(24))))
        try await ben.store.save(PairedPeer(publicKey: mallory.key, nickname: "mallory", pairedAt: Timestamp(T.now)))
        return (world, ben, mallory)
    }

    /// Runs PSI as the initiator with every slot from 19:00 to 23:00.
    func openRun(from mallory: RawPeer, to ben: DownNode, elementCount: Int = DownTokenSet.setSize) async throws -> ConversationID {
        let wide = DownTokenSet(constraints: try T.constraints(time: [T.slot(19, 23)]), now: T.now, expiresAt: T.at(24), timeZone: TimeZone(identifier: "UTC")!)
        var elements = wide.elements
        while elements.count < elementCount { elements.insert(try PSIElement(Data("extra-\(elements.count)".utf8))) }
        let configuration = try PSIConfiguration(output: .intersection, maxPeerSetSize: 100, maxLocalSetSize: 100)
        let session = try InsecurePSIStub().makeSession(role: .initiator, localSet: elements, configuration: configuration)
        guard case .send(let request) = try await session.start() else { throw ValidationError("test", "no request") }
        let conversation = ConversationID()
        try await mallory.send(.psi(try PSIFrame(session: UUID(), step: 0, payload: request)), to: ben.id, in: conversation)
        return conversation
    }

    // MARK: - Malicious friend

    @Test func offersThatBreakLimitsAreRepairedInCodeAndForgedAcceptsIgnored() async throws {
        let (world, ben, mallory) = try await benAndMallory()
        let conversation = try await openRun(from: mallory, to: ben)
        _ = try await mallory.next(.psi)

        // Too late, too expensive, and an avoided activity.
        let greedy = try T.plan(time: T.slot(19, 23), activity: ["sushi", "tacos"], budget: 100)
        try await mallory.send(.propose(try Proposal(round: 0, terms: greedy)), to: ben.id, in: conversation)
        let counter = try await mallory.next(.counter)
        guard case .counter(let repaired) = counter.body else { return }
        #expect(repaired.terms == (try T.plan(time: T.slot(19, 22), activity: ["tacos"], budget: 15)))

        // Accepting a plan Ben never offered, even with a valid level, does nothing.
        var forged = greedy.values
        forged[DownProfile.levelKey] = .keywords([T.keyword("down")])
        try await mallory.send(.accept(Acceptance(proposal: counter.id, terms: try Terms(forged))), to: ben.id, in: conversation)
        // Neither does an accept of Ben's plan without a level.
        try await mallory.send(.accept(Acceptance(proposal: counter.id, terms: repaired.terms)), to: ben.id, in: conversation)

        // Keep pushing until the round limit.
        try await mallory.send(.counter(try Proposal(round: 2, terms: greedy, inReplyTo: counter.id)), to: ben.id, in: conversation)
        let second = try await mallory.next(.counter, skipping: 1)
        try await mallory.send(.counter(try Proposal(round: 4, terms: greedy, inReplyTo: second.id)), to: ben.id, in: conversation)
        try await mallory.send(.counter(try Proposal(round: 3, terms: greedy, inReplyTo: second.id)), to: ben.id, in: conversation)
        _ = try await mallory.next(.reject)
        try await world.settle()

        #expect(await ben.log.notifications.isEmpty)
        #expect(await ben.negotiator.diagnostics.gateRefusals == 0)
        await world.expectNoViolations(["ben": Self.benRules])
        // Ben's level never left the phone.
        #expect(await !world.wire.sent(by: ben.id).contains { DownFlowTests.mentionsLevel($0.body) })
        await mallory.stop()
        await world.stop()
    }

    @Test func anOversizedPSISetIsRefusedWithoutAReply() async throws {
        let (world, ben, mallory) = try await benAndMallory()
        _ = try await openRun(from: mallory, to: ben, elementCount: DownTokenSet.setSize + 1)
        try await eventually("ben saw it") { await ben.negotiator.diagnostics.outcomes[.failed] == 1 }
        try await world.settle()
        #expect(await world.wire.sent(by: ben.id).isEmpty)
        await mallory.stop()
        await world.stop()
    }

    @Test func anUnpairedPeerGetsNoReply() async throws {
        let world = DownWorld(["ben"])
        let stranger = RawPeer(hub: world.hub)
        try await world.start()
        try await stranger.start()
        let ben = world["ben"]
        try await ben.negotiator.setIntent(DownIntent(rules: OwnerRules(constraints: Self.benRules), level: .down, expiresAt: Timestamp(T.at(24))))
        _ = try await openRun(from: stranger, to: ben)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await world.wire.sent(by: ben.id).isEmpty)
        #expect(await ben.negotiator.conversations.isEmpty)
        await stranger.stop()
        await world.stop()
    }

    @Test func aFriendCannotRunPSIOverAndOverToMapFreeTime() async throws {
        let (world, ben, mallory) = try await benAndMallory()
        // One run at a time: Ben ignores a new run while one is open.
        for _ in 0..<5 {
            _ = try await openRun(from: mallory, to: ben)
            try await world.settle()
        }
        let replies = await world.wire.sent(by: ben.id).filter { $0.body.kind == .psi }
        #expect(replies.count == fastConfiguration.maxRunsPerPeer)
        await mallory.stop()
        await world.stop()
    }

    // MARK: - Misbehaving model

    /// Suggests avoided and invented activities, and counters with a plan
    /// that breaks every limit.
    static func hostileModel(calls: Counter) -> ScriptedAgentModel {
        ScriptedAgentModel(
            onMatch: { wanted, offered in
                await calls.increment()
                return [
                    KeywordMatch(wanted: wanted[0], offered: T.keyword("sushi"), strength: .satisfies),
                    KeywordMatch(wanted: wanted[0], offered: T.keyword("pizza"), strength: .satisfies),
                ]
            },
            onDecide: { _ in
                await calls.increment()
                return .counter(try T.plan(time: T.slot(18, 23), activity: ["sushi"], budget: 100))
            }
        )
    }

    /// Two phones where the lower peer ID starts the run (it wins a
    /// simultaneous start), so tests can choose who answers.
    func pair(model: any AgentModel, starter: (DownNode) async throws -> Void, answerer: (DownNode) async throws -> Void) async throws -> (DownWorld, DownNode, DownNode) {
        let world = DownWorld(["x", "y"], model: model)
        try await world.start()
        let (low, high) = world["x"].id < world["y"].id ? (world["x"], world["y"]) : (world["y"], world["x"])
        try await starter(low)
        try await answerer(high)
        return (world, low, high)
    }

    @Test func modelMatchesThatBreakLimitsNeverReachTheWire() async throws {
        let calls = Counter()
        let (world, starter, answerer) = try await pair(
            model: Self.hostileModel(calls: calls),
            starter: { try await $0.want(time: [T.slot(19, 22)], liked: ["sushi", "food"]) },
            answerer: { try await $0.want(time: [T.slot(19, 22)], liked: ["food"], avoided: ["sushi"], maxBudget: 15) }
        )
        try await eventually("both matched") { await matchCounts(starter, answerer) == [1, 1] }
        try await world.settle()
        #expect(await answerer.log.matches.first?.terms[.activity] == .keywords([T.keyword("food")]))
        #expect(await calls.value == 1)
        await world.expectNoViolations([answerer.name: try T.constraints(time: [T.slot(19, 22)], liked: ["food"], avoided: ["sushi"], maxBudget: 15)])
        #expect(await answerer.negotiator.diagnostics.gateRefusals == 0)
        await world.stop()
    }

    @Test func aModelCounterThatBreaksLimitsIsReplacedByAccept() async throws {
        let calls = Counter()
        let rules = try T.constraints(time: [T.slot(19, 22)], liked: ["food"], avoided: ["sushi"], maxBudget: 15)
        let (world, starter, answerer) = try await pair(
            model: Self.hostileModel(calls: calls),
            starter: { try await $0.want(time: [T.slot(19, 22)]) },
            answerer: { try await $0.want(time: [T.slot(19, 22)], liked: ["food"], avoided: ["sushi"], maxBudget: 15) }
        )
        try await eventually("both matched") { await matchCounts(starter, answerer) == [1, 1] }
        try await world.settle()
        // The answerer asked the model once, ignored its illegal counter, and accepted.
        #expect(await calls.value == 1)
        #expect(await answerer.log.matches.first?.terms == (try T.plan(time: T.slot(19, 21))))
        await world.expectNoViolations([answerer.name: rules])
        #expect(await answerer.negotiator.diagnostics.gateRefusals == 0)
        await world.stop()
    }

    @Test func aModelThatIsUnavailableFallsBackToPlainLogic() async throws {
        let broken = ScriptedAgentModel(
            onMatch: { _, _ in throw AgentModelError.unavailable(reason: "test") },
            onDecide: { _ in throw AgentModelError.interrupted }
        )
        let (world, starter, answerer) = try await pair(
            model: broken,
            starter: { try await $0.want(time: [T.slot(19, 22)], liked: ["tacos", "food"]) },
            answerer: { try await $0.want(time: [T.slot(20, 23)], liked: ["food"]) }
        )
        try await eventually("both matched") { await matchCounts(starter, answerer) == [1, 1] }
        // Only the exact match survives without the model.
        #expect(await starter.log.matches.first?.terms[.activity] == .keywords([T.keyword("food")]))
        await world.stop()
    }

    // MARK: - The gate itself

    @Test func theGateRefusesEveryKindOfViolatingBody() throws {
        let rules = OwnerRules(constraints: Self.benRules)
        let profile = DownProfile(intent: DownIntent(rules: rules, level: .down, expiresAt: Timestamp(T.at(24))), now: T.now, timeZone: TimeZone(identifier: "UTC")!)
        let good = try T.plan(time: T.slot(19, 20), activity: ["tacos"], budget: 10)
        let bad = try T.plan(time: T.slot(19, 20), activity: ["sushi"], budget: 10)
        let id = MessageID()

        #expect(DownNegotiator.passesGate(.propose(try Proposal(round: 0, terms: good)), profile: profile))
        #expect(!DownNegotiator.passesGate(.propose(try Proposal(round: 0, terms: bad)), profile: profile))
        #expect(!DownNegotiator.passesGate(.counter(try Proposal(round: 1, terms: try T.plan(time: T.slot(19, 20), budget: 16))), profile: profile))
        #expect(DownNegotiator.passesGate(.accept(Acceptance(proposal: id, terms: profile.accepting(good))), profile: profile))
        #expect(!DownNegotiator.passesGate(.accept(Acceptance(proposal: id, terms: good)), profile: profile))
        #expect(!DownNegotiator.passesGate(.accept(Acceptance(proposal: id, terms: profile.accepting(bad))), profile: profile))
        #expect(!DownNegotiator.passesGate(.query(try Query(issue: .activity, candidates: .keywords([T.keyword("sushi")]))), profile: profile))
        #expect(!DownNegotiator.passesGate(.answer(try Answer(query: id, status: .answered, acceptable: .keywords([T.keyword("sushi")]))), profile: profile))
        #expect(!DownNegotiator.passesGate(.answer(try Answer(query: id, status: .answered, acceptable: .amount(T.usd(20)))), profile: profile))
        #expect(DownNegotiator.passesGate(.answer(try Answer(query: id, status: .declined)), profile: profile))
    }
}
