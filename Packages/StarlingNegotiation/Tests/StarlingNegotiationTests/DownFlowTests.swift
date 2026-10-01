import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingNegotiation
import StarlingTransport
import Testing

/// End-to-end Down flows between phones on a Loopback hub, through Outbox and
/// Inbox, with the insecure PSI stub and a scripted model. These are the
/// lane F acceptance criteria.
@Suite(.timeLimit(.minutes(1))) struct DownFlowTests {
    /// Fuzzy matching as the real model does it in the Phase 0 bench:
    /// "food" is satisfied by "boba run" and "tacos". Counts calls.
    static func fuzzyModel(calls: Counter = Counter()) -> ScriptedAgentModel {
        let related: Set<[String]> = [["food", "boba run"], ["boba run", "food"], ["food", "tacos"], ["tacos", "food"]]
        return ScriptedAgentModel(
            onMatch: { wanted, offered in
                await calls.increment()
                var matches = ScriptedAgentModel.exactMatches(wanted: wanted, offered: offered)
                for want in wanted {
                    for offer in offered where related.contains([want.value, offer.value]) {
                        matches.append(KeywordMatch(wanted: want, offered: offer, strength: .satisfies))
                    }
                }
                return matches
            },
            onDecide: { context in
                await calls.increment()
                return .accept
            }
        )
    }

    // MARK: - Mutual match

    @Test func mutualInterestNotifiesBothSidesWithTheSamePlan() async throws {
        let calls = Counter()
        let world = DownWorld(["ana", "ben"], model: Self.fuzzyModel(calls: calls))
        try await world.start()
        let (ana, ben) = (world["ana"], world["ben"])
        try await ana.want(time: [T.slot(19, 22)], liked: ["food"], maxBudget: 15)
        try await ben.want(time: [T.slot(20, 23)], liked: ["boba run"], maxBudget: 20)

        try await eventually("both matched") { await matchCounts(ana, ben) == [1, 1] }
        try await world.settle()
        let fromAna = try #require(await ana.log.matches.first)
        let fromBen = try #require(await ben.log.matches.first)

        #expect(fromAna.peer == ben.id)
        #expect(fromBen.peer == ana.id)
        #expect(fromAna.terms == fromBen.terms)
        #expect(fromAna.bothDown && fromBen.bothDown)
        #expect(fromAna.terms[.time] == .slots([T.slot(20, 22)]))
        #expect(fromAna.terms[.budget] == .amount(T.usd(15)))
        // Whoever asked, the fuzzy match picked the asker's own wording.
        #expect([.keywords([T.keyword("food")]), .keywords([T.keyword("boba run")])].contains(fromAna.terms[.activity]))
        // One match call on the answering side, no decide.
        #expect(await calls.value == 1)
        // Still exactly one notification each after every retry has settled.
        #expect(await matchCounts(ana, ben) == [1, 1])

        await world.expectNoFalseMatches()
        await world.expectNoViolations([
            "ana": try T.constraints(time: [T.slot(19, 22)], liked: ["food"], maxBudget: 15),
            "ben": try T.constraints(time: [T.slot(20, 23)], liked: ["boba run"], maxBudget: 20),
        ])
        await world.stop()
    }

    @Test func everyPSIStepDeclaresItsProviderAndInputsToThePolicy() async throws {
        // Like lane G's policy: a PSI step without its context is refused.
        let policy = FixedPolicyEngine { message in
            guard case .psi = message.envelope.body, message.context.psi == nil else { return .allow }
            return .deny(PolicyViolation(rule: "psi-needs-context"))
        }
        let world = DownWorld(["ana", "ben"], policy: policy)
        try await world.start()
        let (ana, ben) = (world["ana"], world["ben"])
        try await ana.want(time: [T.slot(19, 21)])
        try await ben.want(time: [T.slot(20, 22)])
        try await eventually("both matched") { await matchCounts(ana, ben) == [1, 1] }
        try await world.settle()

        let windows = [ana.id: T.slot(19, 21), ben.id: T.slot(20, 22)]
        let psiSteps = await policy.evaluated.filter { $0.envelope.body.kind == .psi }
        #expect(psiSteps.count >= 2)
        for step in psiSteps {
            let context = try #require(step.context.psi)
            #expect(context.provider == InsecurePSIStub().descriptor)
            // The inputs are the sender's own free half-hours, exactly.
            guard case .slots(let slots)? = context.inputs[.time], let window = windows[step.envelope.sender] else {
                Issue.record("no time inputs")
                continue
            }
            #expect(Set(context.inputs.keys) == [.time])
            #expect(DownProfile.merge(slots) == [window])
        }
        await world.stop()
    }

    @Test func eachPairOfFriendsMatchesOnItsOwn() async throws {
        let world = DownWorld(["ana", "ben", "cai"], model: Self.fuzzyModel())
        try await world.start()
        try await world["ana"].want(time: [T.slot(19, 21)], liked: ["food"])
        try await world["ben"].want(time: [T.slot(20, 23)], liked: ["tacos"])
        try await world["cai"].want(time: [T.slot(22, 23)])

        try await eventually("ana-ben and ben-cai matched") {
            await matchCounts(world["ana"], world["ben"], world["cai"]) == [1, 2, 1]
        }
        try await world.settle()
        #expect(await world["ana"].log.matches.map(\.peer) == [world["ben"].id])
        #expect(await Set(world["ben"].log.matches.map(\.peer)) == [world["ana"].id, world["cai"].id])
        #expect(await world["cai"].log.matches.map(\.peer) == [world["ben"].id])
        // Ana and Cai share no time: they exchanged PSI frames and nothing else.
        let anaCai = await world.wire.envelopes.filter {
            Set([$0.sender, $0.recipient]) == [world["ana"].id, world["cai"].id]
        }
        #expect(anaCai.allSatisfy { $0.body.kind == .psi })
        await world.expectNoFalseMatches()
        await world.stop()
    }

    // MARK: - One-sided interest

    @Test func oneSidedInterestNotifiesNoOneAndTheOtherPhoneSendsNothing() async throws {
        let world = DownWorld(["ana", "ben"])
        try await world.start()
        let (ana, ben) = (world["ana"], world["ben"])
        try await ana.want(time: [T.slot(19, 22)], liked: ["food"], maxBudget: 15, level: .maybe)

        try await eventually("ana tried") { await !world.wire.sent(by: ana.id).isEmpty }
        try await world.settle()

        #expect(await ana.log.notifications.isEmpty)
        #expect(await ben.log.notifications.isEmpty)
        #expect(await world.wire.sent(by: ben.id).isEmpty)
        #expect(await world.wire.kinds(from: ana.id).allSatisfy { $0 == .psi })
        #expect(await ana.negotiator.diagnostics.outcomes == [.timedOut: 1])
        await world.stop()
    }

    @Test func noSharedTimeEndsSilentlyAfterAnEmptyPSIResult() async throws {
        let world = DownWorld(["ana", "ben"])
        try await world.start()
        let (ana, ben) = (world["ana"], world["ben"])
        try await ana.want(time: [T.slot(19, 20)], liked: ["food"])
        try await ben.want(time: [T.slot(21, 23)], liked: ["food"])

        try await eventually("both ran PSI") { await world.wire.haveSent([ana.id, ben.id]) }
        try await world.settle()

        #expect(await ana.log.notifications.isEmpty)
        #expect(await ben.log.notifications.isEmpty)
        #expect(await world.wire.envelopes.allSatisfy { $0.body.kind == .psi })
        #expect(await ana.negotiator.diagnostics.outcomes[.noOverlap] == 1)
        #expect(await ben.negotiator.diagnostics.outcomes[.noOverlap] == 1)
        await world.stop()
    }

    @Test func noSharedActivityEndsSilentlyWithoutAnOffer() async throws {
        let world = DownWorld(["ana", "ben"])
        try await world.start()
        try await world["ana"].want(time: [T.slot(19, 22)], liked: ["climbing"], avoided: ["movie"])
        try await world["ben"].want(time: [T.slot(19, 22)], liked: ["movie"], avoided: ["climbing"])
        try await eventually("someone asked") { await world.wire.envelopes.contains { $0.body.kind == .answer } }
        try await world.settle()
        #expect(await world["ana"].log.notifications.isEmpty)
        #expect(await world["ben"].log.notifications.isEmpty)
        #expect(await !world.wire.envelopes.contains { [.propose, .counter, .accept].contains($0.body.kind) })
        await world.stop()
    }

    @Test func unpairedPhonesNeverExchangeDownTraffic() async throws {
        let world = DownWorld(["ana", "ben"])
        try await world.start(pairAll: false)
        try await world["ana"].want(time: [T.slot(19, 22)])
        try await world["ben"].want(time: [T.slot(19, 22)])
        try await Task.sleep(for: .milliseconds(200))
        #expect(await world.wire.envelopes.isEmpty)
        await world.stop()
    }

    // MARK: - Maybe

    @Test func maybeIsRevealedOnlyInsideTheFinalAccepts() async throws {
        let world = DownWorld(["ana", "ben"], model: Self.fuzzyModel())
        try await world.start()
        let (ana, ben) = (world["ana"], world["ben"])
        try await ana.want(time: [T.slot(19, 22)], liked: ["food"], level: .maybe)
        try await ben.want(time: [T.slot(20, 23)], liked: ["tacos"])

        try await eventually("both matched") { await matchCounts(ana, ben) == [1, 1] }
        try await world.settle()
        #expect(await ana.log.matches.first?.bothDown == false)
        #expect(await ben.log.matches.first?.bothDown == false)

        // The level key appears in exactly the two accepts, one per side.
        let carrying = await world.wire.envelopes.filter { Self.mentionsLevel($0.body) }
        #expect(Set(carrying.map(\.body.kind)) == [.accept])
        #expect(Set(carrying.map(\.sender)) == [ana.id, ben.id])
        await world.stop()
    }

    @Test func aMaybeWithoutMutualInterestNeverLeavesThePhone() async throws {
        for bensTime in [nil, [T.slot(22, 23)]] {
            let world = DownWorld(["ana", "ben"], model: Self.fuzzyModel())
            try await world.start()
            try await world["ana"].want(time: [T.slot(19, 21)], liked: ["food"], level: .maybe)
            if let bensTime { try await world["ben"].want(time: bensTime, level: .maybe) }
            try await eventually("ana tried") { await !world.wire.sent(by: world["ana"].id).isEmpty }
            try await world.settle()
            #expect(await !world.wire.envelopes.contains { Self.mentionsLevel($0.body) })
            #expect(await world["ana"].log.notifications.isEmpty)
            #expect(await world["ben"].log.notifications.isEmpty)
            await world.stop()
        }
    }

    static func mentionsLevel(_ body: MessageBody) -> Bool {
        switch body {
        case .propose(let proposal), .counter(let proposal): proposal.terms[DownProfile.levelKey] != nil
        case .accept(let acceptance): acceptance.terms[DownProfile.levelKey] != nil
        case .query(let query): query.issue == DownProfile.levelKey
        default: false
        }
    }

    // MARK: - Lost frames and partitions

    @Test func lostFramesAreRetriedAndBothSidesStillMatchOnce() async throws {
        let world = DownWorld(["ana", "ben"], model: Self.fuzzyModel())
        let (ana, ben) = (world["ana"], world["ben"])
        for node in [ana, ben] {
            for kind in [MessageBody.Kind.psi, .query, .answer, .propose, .accept] {
                await node.transport.lose(1) { $0.body.kind == kind }
            }
        }
        try await world.start()
        try await ana.want(time: [T.slot(19, 22)], liked: ["food"], maxBudget: 15)
        try await ben.want(time: [T.slot(20, 23)], liked: ["food"], maxBudget: 20)

        try await eventually("both matched") { await matchCounts(ana, ben) == [1, 1] }
        try await world.settle()
        #expect(await ana.log.matches.count == 1)
        #expect(await ben.log.matches.count == 1)
        #expect(await ana.log.matches.first?.terms == ben.log.matches.first?.terms)
        #expect(await ana.transport.lost.count + ben.transport.lost.count >= 4)
        await world.expectNoFalseMatches()
        await world.stop()
    }

    @Test func aPartitionMidRunEndsSilentlyAndAHealRetries() async throws {
        let world = DownWorld(["ana", "ben"], model: Self.fuzzyModel())
        let (ana, ben) = (world["ana"], world["ben"])
        // After PSI, nothing more gets through in either direction.
        await ana.transport.lose { $0.body.kind != .psi }
        await ben.transport.lose { $0.body.kind != .psi }
        try await world.start()
        try await ana.want(time: [T.slot(19, 22)], liked: ["food"])
        try await ben.want(time: [T.slot(20, 23)], liked: ["food"])

        try await eventually("details attempted") { await ana.transport.lost.count + ben.transport.lost.count > 0 }
        try await world.settle()
        #expect(await ana.log.notifications.isEmpty)
        #expect(await ben.log.notifications.isEmpty)

        await ana.transport.clearRules()
        await ben.transport.clearRules()
        await world.hub.partition(ana.id, ben.id)
        await world.hub.heal(ana.id, ben.id)
        try await eventually("both matched after heal") { await matchCounts(ana, ben) == [1, 1] }
        try await world.settle()
        await world.expectNoFalseMatches()
        await world.stop()
    }

    @Test func friendsWhoMeetOnlyAfterAPartitionHealsStillMatch() async throws {
        let world = DownWorld(["ana", "ben"])
        try await world.start()
        let (ana, ben) = (world["ana"], world["ben"])
        await world.hub.partition(ana.id, ben.id)
        try await ana.want(time: [T.slot(19, 22)])
        try await ben.want(time: [T.slot(20, 23)])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await world.wire.envelopes.isEmpty)

        await world.hub.heal(ana.id, ben.id)
        try await eventually("both matched") { await matchCounts(ana, ben) == [1, 1] }
        await world.stop()
    }

    @Test func lostAcceptsNeverProduceAMatch() async throws {
        let world = DownWorld(["ana", "ben"], model: Self.fuzzyModel())
        let (ana, ben) = (world["ana"], world["ben"])
        await ana.transport.lose { $0.body.kind == .accept }
        await ben.transport.lose { $0.body.kind == .accept }
        try await world.start()
        try await ana.want(time: [T.slot(19, 22)], liked: ["food"])
        try await ben.want(time: [T.slot(20, 23)], liked: ["food"])
        try await eventually("an accept was tried") { await ana.transport.lost.count + ben.transport.lost.count > 0 }
        try await world.settle()
        #expect(await ana.log.notifications.isEmpty)
        #expect(await ben.log.notifications.isEmpty)
        await world.stop()
    }

    @Test func aLostConfirmationCostsTheAcceptorItsNotificationButNeverFakesOne() async throws {
        let world = DownWorld(["ana", "ben"], model: Self.fuzzyModel())
        let (ana, ben) = (world["ana"], world["ben"])
        // A confirmation is an accept of the sender's own offer. Lose all of them.
        for node in [ana, ben] {
            await node.transport.lose { envelope, ownSends in
                guard case .accept(let acceptance) = envelope.body else { return false }
                return ownSends.contains(acceptance.proposal)
            }
        }
        try await world.start()
        try await ana.want(time: [T.slot(19, 22)], liked: ["food"])
        try await ben.want(time: [T.slot(20, 23)], liked: ["food"])
        try await eventually("offerer matched") { await matchCounts(ana, ben).reduce(0, +) == 1 }
        try await world.settle()
        // The offerer holds the acceptor's accept, so its match is real; the
        // acceptor never saw a confirmation and stays silent.
        #expect(await matchCounts(ana, ben).reduce(0, +) == 1)
        await world.expectNoFalseMatches()
        await world.stop()
    }
}
