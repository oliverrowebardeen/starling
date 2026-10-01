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
