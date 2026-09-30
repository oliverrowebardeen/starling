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
}
