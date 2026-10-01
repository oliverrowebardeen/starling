# ADR 0144: Wiring lane F's Down, and a simulated friend until the secure channel

- Status: Proposed
- Date: 2026-10-01
- Owner: H (App features)

## Context

Lane F's `DownNegotiator` is merged. `docs/requests/F.md` ("Answers to lane H") sets the app's side: build it on the app's `Outbox`, pass every `InboxEvent` to `handle(_:)`, send `hello` from the app's link layer (Down records cards but never sends one), keep the review open on `DownError.expired` and `.noAvailableTime`, call `shutdown()` on teardown, read `psiProvider.isPrivate`, and put the intent's constraints before the standing ones. The only PSI provider is `InsecurePSIStub`, which lives in `StarlingFakes`, and Release builds must not link `StarlingFakes` (ADR 0140). Lane E1's secure channel is not wired, so the app has no authenticated link to a real friend yet.

## Decision

1. **The Down service is built on the app's Outbox** (`AppServices.makeDownService: (Outbox) -> DownService`): lane G's policy through `RulesPolicy`, the consent sheet, and the audit log apply to every Down send. No Outbox, no Down.
2. **The app's link layer greets peers.** On each `peerAvailable` the Inbox loop sends a `hello` with this agent's card (`[.down, .psi]`, the model's locality) before handing the event to Down. Without a card, lane G's policy treats a friend's model location as unknown. `hello` is always allowed and carries nothing else.
3. **Release keeps "Down? isn't in this build yet"** until a private PSI provider exists outside `StarlingFakes` (Nightjar), as the Orchestrator directed. Moving `InsecurePSIStub` out of `StarlingFakes` is the Orchestrator's call.
4. **Debug builds run the real Down against a simulated friend** on an in-process `LoopbackHub`: a second `DownNegotiator`, paired with this phone through key-derived IDs, that allows its own sends and approves its own consent, so only this phone's side exercises lane G's policy and the consent sheet. Developer > Simulated friend makes it go down, maybe, withdraw, or walk out of range. The scripted model (Developer toggle) accepts offers so the journey also runs where Foundation Models cannot.
5. **A headless self-test** (`-starlingSelfTestDown YES`, Debug only) runs the whole journey and prints each consent request, the match, and the audit log, because the Simulator cannot be tapped through. On the iOS 27 Simulator it matched (food, $15.00, both down) in two runs, with the audit log `hello, psi, psi, answer, answer, accept` when the simulated friend started the exchange and `hello, psi, query, query, propose, accept` when this phone did.
6. **Teardown** calls `AppModel.shutdown()` on `willTerminateNotification`: the loop ends, `DownNegotiator.shutdown()` runs, the transport stops.

## Consequences

- When E1 merges, the app's transport becomes the secure channel over LocalP2P and Wi-Fi Aware with one shared pin authority, the Loopback harness stays as a Debug tool, and the simulated friend can remain for single-phone testing.
- Each consent-requiring step must be answered within lane F's step deadline (30 s, 60 s for details); a sheet left longer is dropped when F cancels the send, which `ConsentCoordinator` already handles.
- While the PSI provider is not private the review says matching does not hide free times, and lane G's sheet shows the full input set.

## Sources

- `docs/requests/F.md`, "Answers to lane H"; ADR 0120 and 0121 (lane F).
- StarlingPolicy README: `hello` always allowed; cards and locality.
- ADR 0140 (no fakes in Release), ADR 0141 (merge), ADR 0142 (consent).
