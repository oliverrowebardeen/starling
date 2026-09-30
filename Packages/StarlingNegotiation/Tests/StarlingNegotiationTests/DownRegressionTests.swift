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
}
