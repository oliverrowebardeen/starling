import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

@Suite struct SendFailureMessageTests {
    @Test func everyOutboxRefusalSaysNothingWasSent() {
        let errors: [any Error] = [
            OutboxError.consentDeclined,
            OutboxError.policyChangedDuringConsent,
            OutboxError.denied(PolicyViolation(rule: "never", issue: .place)),
            CancellationError(),
        ]
        for error in errors {
            let text = SendFailureMessage.text(for: error)
            #expect(text?.contains("nothing") == true, "\(error)")
        }
        #expect(SendFailureMessage.text(for: OutboxError.policyChangedDuringConsent)?.contains("changed while you were deciding") == true)
    }

    @Test func otherErrorsAreLeftToTheCaller() {
        #expect(SendFailureMessage.text(for: TransportError.notStarted) == nil)
    }
}

/// A DownService whose setIntent fails the way lane F's may when its first
/// send goes through Outbox.
actor FailingDownService: DownService {
    nonisolated let events: AsyncStream<DownEvent>
    let error: any Error

    init(_ error: any Error) {
        self.error = error
        events = AsyncStream { _ in }
    }

    func setIntent(_ intent: DownIntent) async throws { throw error }
    func clearIntent() async {}
    func handle(_ event: InboxEvent) async {}
}

@MainActor
@Suite struct DownSendFailureTests {
    func model(failingWith error: any Error) -> DownModel {
        DownModel(
            service: FailingDownService(error),
            interpreter: RulesInterpreter(agent: nil, issues: RulesInterpreter.intentIssues),
            rules: InMemoryRulesStore(),
            peers: InMemoryPairedPeerStore(),
            notifier: RecordingNotifier()
        )
    }

    @Test func policyChangeDuringConsentKeepsTheReviewOpenAndExplains() async {
        let model = model(failingWith: OutboxError.policyChangedDuringConsent)
        await model.editByHand()
        await model.goDown()
        #expect(model.phase == .reviewing)
        #expect(model.notice == SendFailureMessage.text(for: OutboxError.policyChangedDuringConsent))
        #expect(model.active == nil)
    }

    @Test func declinedConsentIsNotReportedAsAnError() async {
        let model = model(failingWith: OutboxError.consentDeclined)
        await model.editByHand()
        await model.goDown()
        #expect(model.notice == "It wasn't approved, so nothing left your phone.")
    }

    @Test func otherFailuresUseTheGenericMessage() async {
        let model = model(failingWith: TransportError.notStarted)
        await model.editByHand()
        await model.goDown()
        #expect(model.notice == "Starling couldn't start checking. Try again.")
    }
}
