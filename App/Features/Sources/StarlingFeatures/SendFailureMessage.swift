import StarlingCore

/// Plain words for a send that `Outbox` refused. Each says that nothing left
/// the phone, because that is what every one of these errors guarantees.
public enum SendFailureMessage {
    /// Nil when `error` is not a refusal to send (for example a transport
    /// failure), so callers fall back to their own wording.
    public static func text(for error: any Error) -> String? {
        switch error {
        // Also what a consent timeout looks like, so it does not say "you chose".
        case OutboxError.consentDeclined:
            "It wasn't approved, so nothing left your phone."
        case OutboxError.policyChangedDuringConsent:
            "Your sharing rules changed while you were deciding, so nothing was sent. Check your rules and try again."
        case OutboxError.denied:
            "Your sharing rules don't allow this, so nothing was sent."
        case is CancellationError:
            "Stopped before sending, so nothing left your phone."
        default:
            nil
        }
    }
}
