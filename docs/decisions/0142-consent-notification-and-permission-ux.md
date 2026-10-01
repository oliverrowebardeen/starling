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

1. **Consent.** `ConsentCoordinator` is the app's `ConsentProvider`. Only an explicit "Send" approves. The sheet cannot be swiped away; "Don't send", a two-minute timeout, and cancellation of the requesting task all decline. Requests queue one at a time, and an answer applies only to the request its sheet displayed (`answer(_:to:)`), so a sheet on its way out cannot answer the request queued behind it. A cancelled request leaves the queue at once, and its sheet is dismissed if it was showing. The sheet names the friend by local nickname; its rows and notices come from lane G's `ConsentSheetModel`, so it shows exactly what the policy computed would be sent, including G's notices that model location is self-declared, what a non-private matching step reveals, and the protocol metadata every message carries.
2. **Remembered approvals.** Lane F resends a Down step up to six times and every `Outbox.send` evaluates the policy again, so without memory every retry of a consent-requiring step would raise a sheet (F request 5). `ConsentCoordinator` remembers an explicit approval for 10 minutes and approves an equal `Disclosure` without a sheet. Equality covers the recipient, the recipient's claimed model location, and every item, so a changed locality claim or any changed value asks again. The memory is cleared whenever the Down intent starts, is withdrawn, or ends, so an approval never outlives its intent. Declines, timeouts, and cancellations are never remembered. A request for the identical disclosure that is already queued while the sheet is open gets the owner's answer to that same question, decline included; nothing about a decline is kept after that.
3. **One policy that follows the rules.** The app's `Outbox` uses lane G's `DeterministicPolicyEngine` through `RulesPolicy`, which rebuilds the engine whenever the owner's effective rules change: the saved rules, merged with the active Down intent while one is out. The Down intent's rules are applied before `DownService.setIntent` runs. `RulesPolicy` denies every send until the saved rules have loaded, and keeps denying if they exist but cannot be read (they may hold "never share" rules the app cannot see) until the owner saves rules again; the Rules tab says so. `InMemoryAuditLog` is the Outbox observer.
4. **Refused sends.** Core v1.1 re-checks the policy after consent and throws `OutboxError.policyChangedDuringConsent` if its answer changed. The app shows each Outbox refusal in words that say nothing was sent (`SendFailureMessage`), including "Your sharing rules changed while you were deciding", and keeps the Down review open.
5. **Notifications.** Only `DownEvent.matched` notifies. `MatchNotice` can be built only from a `DownMatch`, and `DownModel` is the only caller of `MatchNotifier.post`. The request identifier is per friend (`down-match-<peer>`); Apple documents that reusing an identifier replaces the earlier request, so repeated matches with one friend do not stack. A match where either side said "maybe" reads "both interested", never "both down".
6. **Local Network.** Onboarding explains why first, then browses for `_starling._tcp` (already in `NSBonjourServices`) and waits for the browser to become ready or 30 seconds, so the notification prompt never stacks on the Local Network alert. The app's radios (lane E1's secure LocalP2P and Wi-Fi Aware links) start only after this step, or at launch once onboarding is done, because their own Bonjour work would raise the alert before the explanation (ADR 0145).
7. **Honest copy.** Onboarding says this is a test build and that Starling makes no privacy promises until its security is reviewed (ADR 0003: no privacy claim before `docs/THREAT_MODEL.md`).

## Consequences

- F asked for memory keyed by conversation and message body. `ConsentProvider` receives only the `Disclosure`, so memory is keyed on that instead: two different steps that disclose exactly the same values to the same friend within 10 minutes of one intent share one approval. That is the same data leaving to the same person, which is what the owner approved.
- SwiftUI shows one sheet per presenter, so a consent request that arrives while the pairing sheet is open waits until it closes, and declines if two minutes pass. Acceptable for Phase 1; revisit if Down runs during pairing.
- Whether a delivered banner (not only a pending request) is replaced by the same identifier is checked on device (`docs/checklists/phase-1-H.md`).
- Local Network behavior can be tested only on a device.

## Sources

- StarlingPolicy README ("Composition", "Consent data for lane H", "Audit semantics"), `Packages/StarlingPolicy/README.md`.
- App Review Guidelines 5.1.2(i): https://developer.apple.com/app-store/review/guidelines/
- TN3179, Understanding local network privacy: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- `UNNotificationRequest.identifier` ("If you use the same identifier when scheduling a new notification, the system removes the previously scheduled notification with that identifier and replaces it with the new one"): https://developer.apple.com/documentation/usernotifications/unnotificationrequest/identifier
- `UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)`: https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate/usernotificationcenter(_:willpresent:withcompletionhandler:)
