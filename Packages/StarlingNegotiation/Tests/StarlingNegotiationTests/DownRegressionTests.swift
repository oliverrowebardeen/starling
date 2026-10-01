import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingNegotiation
import StarlingTransport
import Testing

/// Regressions from the Codex review of PR #14. Each test reproduces the
/// sequence the review described.
@Suite(.timeLimit(.minutes(1))) struct DownRegressionTests {
    enum Withdrawal: CaseIterable { case clear, replace }

    /// P1: a send waiting on the owner's consent must not go out once its
    /// intent has been withdrawn or replaced.
    @Test(arguments: Withdrawal.allCases)
    func aWithdrawnIntentSendsNothingEvenIfConsentArrivesLater(_ withdrawal: Withdrawal) async throws {
        let consent = GatedConsentProvider()
        let world = DownWorld(["ana", "ben"], policy: consentForEverything([.psi]), consent: consent)
        try await world.start()
        let ana = world["ana"]
        try await ana.want(time: [T.slot(19, 22)])
        try await eventually("the first PSI step waits for consent") { await consent.pending == 1 }

        switch withdrawal {
        case .clear: await ana.negotiator.clearIntent()
        case .replace: try await ana.want(time: [T.slot(20, 23)])
        }
        try await eventually("the replacement's run waits too") { await consent.pending == (withdrawal == .clear ? 1 : 2) }
        await consent.answerAll(.approved)
        try await Task.sleep(for: .milliseconds(60))
        await consent.answerAll(.declined)

        // Only the replacement's run may have reached the wire.
        let conversations = Set(await world.wire.sent(by: ana.id).map(\.conversation))
        #expect(conversations.count == (withdrawal == .clear ? 0 : 1))
        await world.stop()
    }

    /// Two phones where the lower peer ID starts (and so makes the offer).
    static func roles(_ world: DownWorld) -> (offerer: DownNode, acceptor: DownNode) {
        world["ana"].id < world["ben"].id ? (world["ana"], world["ben"]) : (world["ben"], world["ana"])
    }

    /// P1: a lost acceptance must not be replayed after its sender withdrew.
    /// Otherwise the offerer's retry gets the cached accept and it reports a
    /// match while this phone is no longer down.
    @Test func aWithdrawnPhoneDoesNotReplayItsAcceptance() async throws {
        let world = DownWorld(["ana", "ben"])
        let (offerer, acceptor) = Self.roles(world)
        await acceptor.transport.lose { $0.body.kind == .accept }
        try await world.start()
        try await offerer.want(time: [T.slot(19, 22)])
        try await acceptor.want(time: [T.slot(19, 22)])

        try await eventually("the acceptance was lost") { await !acceptor.transport.lost.isEmpty }
        await acceptor.negotiator.clearIntent()
        await acceptor.transport.clearRules()
        try await world.settle()

        #expect(await offerer.log.matches.isEmpty)
        #expect(await !world.wire.sent(by: acceptor.id).contains { $0.body.kind == .accept })
        await world.stop()
    }

    /// P1: after the owner declines consent, a peer's retries must not raise
    /// the consent sheet again.
    @Test func aDeclinedSheetIsNotShownAgainForPeerRetries() async throws {
        let consent = ScriptedConsentProvider(.declined)
        let world = DownWorld(["ana", "ben"], policy: consentForEverything([.accept]), consent: consent)
        let (offerer, acceptor) = Self.roles(world)
        try await world.start()
        try await offerer.want(time: [T.slot(19, 22)])
        try await acceptor.want(time: [T.slot(19, 22)])

        try await eventually("the owner was asked") { await !consent.requests.isEmpty }
        try await world.settle()
        #expect(await consent.requests.count == 1)
        #expect(await matchCounts(offerer, acceptor) == [0, 0])
        await world.stop()
    }

    /// P2: a run that starts late uses only slots still ahead. Both phones
    /// set 19:00 to 22:00 at 19:00 and first reach each other at 21:00.
    @Test func aLateRunOffersOnlyTimeStillAhead() async throws {
        let time = MovableClock()
        let world = DownWorld(["ana", "ben"], clock: time.clock)
        try await world.start()
        let (ana, ben) = (world["ana"], world["ben"])
        await world.hub.partition(ana.id, ben.id)
        try await ana.want(time: [T.slot(19, 22)])
        try await ben.want(time: [T.slot(19, 22)])

        time.set(T.at(21))
        await world.hub.heal(ana.id, ben.id)
        try await eventually("both matched") { await matchCounts(ana, ben) == [1, 1] }
        #expect(await ana.log.matches.first?.terms[.time] == .slots([T.slot(21, 22)]))
        await world.stop()
    }

    /// P2: a stream of distinct queries must not buy model calls or keep a
    /// conversation alive past its details deadline.
    @Test func aFloodOfQueriesCostsOneModelCallAndEndsOnTime() async throws {
        let calls = Counter()
        let model = ScriptedAgentModel(onMatch: { wanted, offered in
            await calls.increment()
            return ScriptedAgentModel.exactMatches(wanted: wanted, offered: offered)
        })
        let world = DownWorld(["ben"], model: model)
        let mallory = RawPeer(hub: world.hub)
        try await world.start()
        try await mallory.start()
        let ben = world["ben"]
        try await eventually("ben sees mallory") { await ben.negotiator.isReachable(mallory.id) }
        try await ben.want(time: [T.slot(19, 22)], liked: ["food"], maxBudget: 15)
        try await ben.store.save(PairedPeer(publicKey: mallory.key, nickname: "mallory", pairedAt: Timestamp(T.now)))

        let conversation = try await DownAdversarialTests().openRun(from: mallory, to: ben)
        _ = try await mallory.next(.psi)
        let clock = ContinuousClock()
        let start = clock.now
        var index = 0
        // Distinct activity and budget queries every 10 ms until Ben's
        // conversation ends, or 2 s (ten times the 2 x 5 x 20 ms details
        // deadline). Before the fix, each answer reset the deadline, so the
        // flood kept the conversation alive indefinitely.
        while clock.now - start < .seconds(2), await !ben.negotiator.conversations.isEmpty || index == 0 {
            let query = index.isMultiple(of: 2)
                ? try Query(issue: .activity, candidates: .keywords([T.keyword("food"), T.keyword("item \(index)")]))
                : try Query(issue: .budget, candidates: .amount(T.usd(Int64(index + 1))))
            try await mallory.send(.query(query), to: ben.id, in: conversation)
            index += 1
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await calls.value == 1)
        #expect(await ben.negotiator.conversations.isEmpty)
        #expect(await ben.negotiator.diagnostics.outcomes[.timedOut] == 1)
        let answers = await world.wire.sent(by: ben.id).filter { $0.body.kind == .answer }
        #expect(answers.count == 2)
        await mallory.stop()
        await world.stop()
    }

    /// P2: when both phones start their last allowed run at once, the
    /// tie-break must win over the run cap. With one run allowed, that is
    /// the very first simultaneous start.
    @Test func aSimultaneousStartOnTheLastAllowedRunStillMatches() async throws {
        var configuration = fastConfiguration
        configuration.maxRunsPerPeer = 1
        let world = DownWorld(["ana", "ben"], configuration: configuration)
        try await world.start()
        let (ana, ben) = (world["ana"], world["ben"])
        try await ana.want(time: [T.slot(19, 22)])
        try await ben.want(time: [T.slot(19, 22)])
        try await eventually("both matched") { await matchCounts(ana, ben) == [1, 1] }
        await world.stop()
    }

    // MARK: - Second review (28c4b87)

    /// P1: withdrawing while the first of two queries waits for consent
    /// must stop the whole batch, not just that send.
    @Test func withdrawingMidBatchSendsNothingElse() async throws {
        let consent = GatedConsentProvider()
        let world = DownWorld(["ana", "ben"], policy: consentForEverything([.query]), consent: consent)
        let (starter, answerer) = Self.roles(world)
        try await world.start()
        // Liked activities and a budget cap: the starter asks two queries.
        try await starter.want(time: [T.slot(19, 22)], liked: ["food"], maxBudget: 15)
        try await answerer.want(time: [T.slot(19, 22)])
        try await eventually("the activity query waits for consent") { await consent.pending == 1 }

        await starter.negotiator.clearIntent()
        // Approve whatever asks next, as an owner tapping through would.
        for _ in 0..<10 {
            await consent.answerAll(.approved)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await consent.requests == 1)
        #expect(await !world.wire.sent(by: starter.id).contains { $0.body.kind == .query })
        await world.stop()
    }

    /// P2: the acceptor's replayed accept names the offerer's retried offer
    /// envelope; the confirmation that answers it must be honored.
    @Test func aConfirmationOfAReplayedAcceptIsHonored() async throws {
        let world = DownWorld(["ana", "ben"])
        let (offerer, acceptor) = Self.roles(world)
        // Every accept naming the first offer envelope the acceptor answered is lost.
        let first = Synchronization.Mutex<MessageID?>(nil)
        await acceptor.transport.lose { envelope in
            guard case .accept(let acceptance) = envelope.body else { return false }
            return first.withLock { original in
                if original == nil { original = acceptance.proposal }
                return original == acceptance.proposal
            }
        }
        try await world.start()
        try await offerer.want(time: [T.slot(19, 22)])
        try await acceptor.want(time: [T.slot(19, 22)])
        try await eventually("both matched") { await matchCounts(offerer, acceptor) == [1, 1] }
        await world.expectNoFalseMatches()
        await world.stop()
    }

    /// P2: a stalled model call must not hold back the deadline that bounds
    /// it, and must not block that friend's later work.
    @Test func aStalledModelCallTimesOutAndDoesNotBlockLaterRuns() async throws {
        let calls = Counter()
        let model = ScriptedAgentModel(onMatch: { wanted, offered in
            if await calls.next() == 1 { try await Task.sleep(for: .seconds(30)) }
            return ScriptedAgentModel.exactMatches(wanted: wanted, offered: offered)
        })
        let world = DownWorld(["ana", "ben"], model: model)
        let (starter, answerer) = Self.roles(world)
        try await world.start()
        try await starter.want(time: [T.slot(19, 22)], liked: ["food"])
        try await answerer.want(time: [T.slot(19, 22)], liked: ["food"])

        // The details deadline is 200 ms and the stall 30 s; 2 s leaves room
        // for a loaded machine.
        try await eventually(timeout: .seconds(2), "the stalled conversation timed out") {
            let started = await calls.value
            let timedOut = await answerer.negotiator.diagnostics.outcomes[.timedOut]
            return started == 1 && timedOut == 1
        }

        await answerer.negotiator.clearIntent()
        try await starter.want(time: [T.slot(19, 22)], liked: ["food"])
        try await answerer.want(time: [T.slot(19, 22)], liked: ["food"])
        try await eventually(timeout: .seconds(2), "a fresh run matched") { await matchCounts(starter, answerer) == [1, 1] }
        await world.stop()
    }

    /// P2: consent (or PSI) delays can carry the exchange past the earliest
    /// shared slot; the opening offer must start no earlier than now.
    @Test func theOpeningOfferSkipsASlotThatStartedDuringTheExchange() async throws {
        let time = MovableClock()
        let consent = GatedConsentProvider()
        let world = DownWorld(["ana", "ben"], policy: consentForEverything([.query]), consent: consent, clock: time.clock)
        let (starter, answerer) = Self.roles(world)
        try await world.start()
        try await starter.want(time: [T.slot(19, 22)], liked: ["food"])
        try await answerer.want(time: [T.slot(19, 22)], liked: ["food"])
        try await eventually("the activity query waits for consent") { await consent.pending == 1 }

        time.set(T.at(19).addingTimeInterval(60))
        await consent.answerAll(.approved)
        try await eventually("both matched") { await matchCounts(starter, answerer) == [1, 1] }
        #expect(await starter.log.matches.first?.terms[.time] == .slots([T.slot(19.5, 21.5)]))
        await consent.answerAll(.declined)
        await world.stop()
    }

    /// P2: if the offerer's confirmation waits on consent past the plan's
    /// start minute, nobody is notified of a plan already under way.
    @Test func aConfirmationThatWaitedPastTheStartNotifiesNoOne() async throws {
        let time = MovableClock()
        let gate = ConsentForOneSender()
        let consent = GatedConsentProvider()
        let world = DownWorld(["ana", "ben"], policy: gate.policy(.accept), consent: consent, clock: time.clock)
        let (offerer, acceptor) = Self.roles(world)
        gate.choose(offerer.id)
        try await world.start()
        try await offerer.want(time: [T.slot(19, 22)])
        try await acceptor.want(time: [T.slot(19, 22)])
        try await eventually("the confirmation waits for consent") { await consent.pending == 1 }

        time.set(T.at(19).addingTimeInterval(60))
        await consent.answerAll(.approved)
        try await world.settle()
        #expect(await matchCounts(offerer, acceptor) == [0, 0])
        await world.stop()
    }

    /// P2: an acceptance still waiting on consent when its plan starts is
    /// cancelled, so it never leaves whenever the owner answers.
    @Test func anAcceptanceWaitingPastTheStartIsCancelled() async throws {
        let time = MovableClock(compressLongSleeps: true)
        let gate = ConsentForOneSender()
        let consent = GatedConsentProvider()
        // Step deadlines (5 x 200 ms, 2 s for details) outlast the plan's
        // start, so only a start-time watchdog can end this in time.
        let slow = DownConfiguration(retryInterval: .milliseconds(200), maxAttempts: 5)
        let world = DownWorld(["ana", "ben"], policy: gate.policy(.accept), consent: consent, clock: time.clock, configuration: slow)
        let (offerer, acceptor) = Self.roles(world)
        gate.choose(acceptor.id)
        try await world.start()
        try await offerer.want(time: [T.slot(19, 22)])
        try await acceptor.want(time: [T.slot(19, 22)])
        try await eventually("the acceptance waits for consent") { await consent.pending == 1 }

        // The plan starts at 19:00; at 19:01 (60 ms here) the watchdog fires.
        try await eventually(timeout: .milliseconds(500), "the acceptor gave up") { await acceptor.negotiator.conversations.isEmpty }
        time.set(T.at(19).addingTimeInterval(60))
        await consent.answerAll(.approved)
        try await world.settle(timeout: .seconds(10))
        #expect(await !world.wire.sent(by: acceptor.id).contains { $0.body.kind == .accept })
        #expect(await matchCounts(offerer, acceptor) == [0, 0])
        await world.stop()
    }

    // MARK: - Third review (0b6099f)

    enum FirstSend: CaseIterable { case asStarter, asResponder }

    /// P2: the first send of a run (PSI request or reply) waiting on an
    /// unanswered consent sheet is bounded by the step's deadline too.
    @Test(arguments: FirstSend.allCases)
    func aFirstPSISendWaitingOnConsentEndsOnTheDeadline(_ role: FirstSend) async throws {
        let gate = ConsentForOneSender()
        let consent = GatedConsentProvider()
        let world = DownWorld(["ben"], policy: gate.policy(.psi), consent: consent)
        let mallory = RawPeer(hub: world.hub)
        try await world.start()
        try await mallory.start()
        let ben = world["ben"]
        gate.choose(ben.id)
        try await eventually("ben sees mallory") { await ben.negotiator.isReachable(mallory.id) }
        let friend = try PairedPeer(publicKey: mallory.key, nickname: "mallory", pairedAt: Timestamp(T.now))
        switch role {
        case .asStarter:
            try await ben.store.save(friend)
            try await ben.want(time: [T.slot(19, 22)])
        case .asResponder:
            try await ben.want(time: [T.slot(19, 22)])
            try await ben.store.save(friend)
            _ = try await DownAdversarialTests().openRun(from: mallory, to: ben)
        }
        try await eventually("ben's first PSI send waits for consent") { await consent.pending == 1 }

        // 5 ticks of 20 ms; the sheet stays unanswered throughout.
        try await eventually(timeout: .seconds(2), "the run timed out") { await ben.negotiator.conversations.isEmpty }
        #expect(await ben.negotiator.diagnostics.outcomes[.timedOut] == 1)
        #expect(await consent.pending == 1)
        await consent.answerAll(.approved)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await world.wire.sent(by: ben.id).isEmpty)
        await mallory.stop()
        await world.stop()
    }
}

import Synchronization
