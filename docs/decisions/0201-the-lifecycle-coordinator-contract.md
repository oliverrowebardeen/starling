# ADR 0201: What the lifecycle coordinator applies, and what skills report

- Status: Proposed
- Date: 2026-09-30
- Owner: P15-A (Shell and IA)

## Context

ADR 0011 gives the app one lifecycle coordinator that consumes every `SkillService`'s `SkillEvent`s, applies them to `Interaction` records, and drives the shared screens. Skills never write interactions. Some `InteractionEvent`s, though, come from the owner rather than from a skill ("the owner, through the shared screens"): sending, I'm in, passing, answering a question, withdrawing, and each consent sheet. The Core v2 interfaces do not say who reports those, and two sources reporting the same event would race:

- A consent sheet appears when `Outbox` calls the app's one `ConsentProvider` in the middle of a skill's send. The skill cannot see that call, so it cannot report `consentNeeded` at the right moment, and two sources allocating consent request IDs would collide (IDs only rise, so the second one is refused).
- If the coordinator applies `ownerAccepted` and the service reports it too, the second copy is an `InvalidTransition` (confirmed does not accept `ownerAccepted`).

## Decision

1. **Skill services report what their agents do:** `incoming`, `ownerNeeded(question)`, `proposalReady(proposal)`, `everyoneConfirmed(revision)`, `noAgreement`, `expired`, `failed`, `unsupported`, `blockedByPrivacy`, and `produced(artifact)`.
2. **The coordinator applies the owner's steps itself, before the service hears of them:**
   - `started` when the owner sends from New, then `SkillService.start(_:)`. If `start` throws, the interaction ends `failed`.
   - `ownerAccepted(revision:)`, `ownerPassed`, and `ownerAnswered(question:)` when the owner taps a card, then `SkillService.answer(_:with:)`. A tap on a stale card throws `StaleProposal` or `StaleQuestion` here and never reaches the service.
   - `withdrawn`, then `SkillService.withdraw(_:)`.
   - A service that reports these anyway is harmless: the copy is dropped as an invalid transition.
3. **Consent events come from the consent sheet, keyed by conversation.** The app's `ConsentProvider` reads `Disclosure.conversation` (v2), and the coordinator suspends that conversation's interaction with `consentNeeded(request:)` under the next ID above its watermark. Approval applies `consentGiven`; Don't send, a timeout, or a cancelled send applies `ownerPassed`, which ends it declined. Skills do not report consent events (request 1 in `docs/requests/P15-A.md`). A remembered approval (ADR 0142) shows no sheet and reports nothing.
4. **The coordinator ends plans** whose `Plan.endsAt` has passed with `planEnded`, at launch and whenever the app comes to the foreground.
5. **Egress is recorded by conversation.** An `OutboxObserver` calls `recordEgress(_:conversation:)` after each successful send; sends outside an interaction (the link layer's `hello`) are not recorded. Lane E's observer plugs in here; until it merges, the app's own observer builds the `DisclosedItem`s with the policy engine's `disclosure(for:)`, the same items the consent sheet shows.
6. **Dropped, not applied.** `InvalidTransition`, `StaleProposal`, `StaleQuestion`, `UnknownConsentRequest`, events for an unknown interaction or another skill's interaction, a repeated `incoming`, and an artifact after the interaction ended all leave the record unchanged. Each is kept in a bounded list (100) shown in the Debug-only Developer section, and logged at debug level.
7. **A peer starts nothing.** `incoming` creates an invitee interaction in negotiating and nothing else. Its `chainedFrom` is a hint only and never creates a `ChainLink` (ADR 0012 decision 6).
8. **Refusals are history.** A request with no friend who runs the skill ends `unsupported`, and one whose required topic is set to Never ends `blockedByPrivacy`, before anything is sent. Both are recorded, so Friends and the timeline can show what happened, and New explains why.
9. **Launch order.** The coordinator loads the store, calls `restore(_:)` on every service with that skill's live interactions, and only then starts consuming events. The app's single Inbox loop reaches the services through the coordinator, which waits for restore first.
10. **Saves are ordered.** Each change updates memory at once and marks the interaction for saving; one writer saves the latest version of each, so a slow write never lands after a newer one.

## Consequences

- Every revision and consent check runs in one place, on the main actor, against the stored record, so the shared screens and the store always agree.
- Skill lanes need not track the owner's taps or consent sheets. Lane B's kickoff mentions consent request IDs; request 1 asks the Orchestrator to confirm decision 3 with lanes B to E.
- Because consent requests are tied to conversations, a send that needs consent before the interaction exists (none today) would not suspend anything. The coordinator creates the interaction and applies `started` before calling `SkillService.start(_:)`, so a skill's first send always has one.

## Sources

- ADR 0011 (decisions 7 to 11), ADR 0012 decision 6, ADR 0142 (consent memory)
- `Packages/StarlingCore/Sources/StarlingCore/Interaction.swift` and `SkillService.swift` (Core v2, c07c036)
- `App/Features/Sources/StarlingFeatures/LifecycleCoordinator.swift` and its tests
