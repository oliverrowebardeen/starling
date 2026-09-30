# ADR 0142: Consent sheet, match notifications, and permission prompts

- Status: Proposed
- Date: 2026-09-30
- Owner: H (App features)

## Context

- Brief 3.7 and App Review guideline 5.1.2(i) require explicit permission before personal data is shared with third parties, and a per-exchange sheet showing exactly which fields leave the phone. `Outbox` calls a `ConsentProvider` whenever the policy returns `needsConsent`.
- Core v1.1: `Outbox` re-evaluates the policy after consent and refuses to send if the answer changed.
- Brief 2.6: notify only on a mutual match; Down to Lunch failed on notification spam.
- A peer's model locality is self-declared (brief open question 4), and the Phase 1 PSI is `InsecurePSIStub`, which reveals the initiator's set.
- iOS has no API to request Local Network access or read its state. The alert appears on the first local network operation; Bonjour browsing is one (TN3179). The Simulator does not support local network privacy.

## Decision

1. **Consent.** `ConsentCoordinator` is the app's `ConsentProvider`. Only an explicit "Send" approves. The sheet cannot be swiped away; "Don't send", a two-minute timeout, and cancellation of the requesting task all decline. Requests queue one at a time. The sheet lists each `DisclosedItem` with its value, names the friend by local nickname, and phrases locality as the peer's claim ("Says its model runs on their iPhone") with "Starling can't check this claim yet". While the PSI is not private (`AppServices.psiIsPrivate == false`), a PSI item carries a note that the matching step does not hide the owner's free times.
2. **Remembered approvals.** Lane F resends a Down step up to six times and every `Outbox.send` evaluates the policy again, so without memory every retry of a consent-requiring step would raise a sheet (F request 5). `ConsentCoordinator` remembers an explicit approval for 10 minutes and approves an equal `Disclosure` without a sheet. Equality covers the recipient, the recipient's claimed model location, and every item, so a changed locality claim or any changed value asks again. The memory is cleared whenever the Down intent starts, is withdrawn, or ends, so an approval never outlives its intent. Declines, timeouts, and cancellations are never remembered. A request for the identical disclosure that is already queued while the sheet is open gets the owner's answer to that same question, decline included; nothing about a decline is kept after that.
3. **Refused sends.** Core v1.1 re-checks the policy after consent and throws `OutboxError.policyChangedDuringConsent` if its answer changed. The app shows each Outbox refusal in words that say nothing was sent (`SendFailureMessage`), including "Your sharing rules changed while you were deciding", and keeps the Down review open.
4. **Notifications.** Only `DownEvent.matched` notifies. `MatchNotice` can be built only from a `DownMatch`, and `DownModel` is the only caller of `MatchNotifier.post`. The request identifier is per friend (`down-match-<peer>`); Apple documents that reusing an identifier replaces the earlier request, so repeated matches with one friend do not stack. A match where either side said "maybe" reads "both interested", never "both down".
5. **Local Network.** Onboarding explains why first, then browses for `_starling._tcp` (already in `NSBonjourServices`) and waits for the browser to become ready or 30 seconds, so the notification prompt never stacks on the Local Network alert.
6. **Honest copy.** Onboarding says this is a test build and that Starling makes no privacy promises until its security is reviewed (ADR 0003: no privacy claim before `docs/THREAT_MODEL.md`).

## Consequences

- F asked for memory keyed by conversation and message body. `ConsentProvider` receives only the `Disclosure`, so memory is keyed on that instead: two different steps that disclose exactly the same values to the same friend within 10 minutes of one intent share one approval. That is the same data leaving to the same person, which is what the owner approved.
- SwiftUI shows one sheet per presenter, so a consent request that arrives while the pairing sheet is open waits until it closes, and declines if two minutes pass. Acceptable for Phase 1; revisit if Down runs during pairing.
- Whether a delivered banner (not only a pending request) is replaced by the same identifier is checked on device (`docs/checklists/phase-1-H.md`).
- Local Network behavior can be tested only on a device.

## Sources

- App Review Guidelines 5.1.2(i): https://developer.apple.com/app-store/review/guidelines/
- TN3179, Understanding local network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- `UNNotificationRequest.identifier` ("If you use the same identifier when scheduling a new notification, the system removes the previously scheduled notification with that identifier and replaces it with the new one"): https://developer.apple.com/documentation/usernotifications/unnotificationrequest/identifier
- `UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)`: https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate/usernotificationcenter(_:willpresent:withcompletionhandler:)
