# ADR 0241: The egress log and the plan's audit

- Status: Proposed
- Date: 2026-10-01
- Owner: P15-E (Chaining and audit)

## Context

ADR 0011 decision 5: the egress log uses the consent sheet's `DisclosedItem`s, recorded by an `OutboxObserver` after each successful send, so "What left your phone" cannot disagree with what the owner approved. The plan detail mockup shows "How this came together" (each skill in the plan, with times, and Swap photos waiting "After 10:30 PM") and "What left your phone" as two lines: Shared ("Boba, after 7 tonight, nearby") and Kept on your phone ("Budget, exact location, calendar").

`OutboxObserver.outbox(didSend:context:decision:)` receives the policy's decision. A send that needed consent carries the sheet's `Disclosure`. A send the policy allowed without a sheet carries `.allow`, which has no items. Lane G's `DeterministicPolicyEngine.disclosure(for:)` computes the items for any message, but StarlingChaining depending on StarlingPolicy is a sideways dependency that needs the Orchestrator's approval (ARCHITECTURE section 1).

ADR 0011 decision 7 makes the lifecycle coordinator the only writer of interactions, and `InteractionStore` has no atomic update, so a second writer could lose an update.

## Decision

1. **`EgressRecorder` is the `OutboxObserver`.** After each send the transport accepted, it records an `EgressRecord` (completion time, recipient, items) on the interaction that owns the envelope's conversation.
   - `needsConsent`: the sheet's own items, exactly.
   - `allow`: the policy's items, through an injected function. The app passes `DeterministicPolicyEngine.disclosure(for:)`'s items. This keeps one implementation of "what does this envelope disclose" without importing StarlingPolicy into this package; `docs/requests/P15-E.md` asks for a Core-level answer.
   - Declined, denied, cancelled, and failed sends are never reported by Outbox, so they are never recorded.
   - A send no interaction owns (a link-level `hello`), items that cannot be computed, and failed writes are counted, not dropped silently. The policy's own audit log still has every send.
2. **The coordinator writes.** The recorder writes through `EgressSink`, which lane A's coordinator implements, so egress records go through the same serialized writer as lifecycle events. `StoreEgressSink` (read, record, save) is for tests and tools.
3. **"What left your phone" is computed, not stored.** `WhatLeftYourPhone` reads the egress logs of a plan's interactions and their skills' descriptors:
   - Shared: each topic that left, its distinct values in the order they first left, who received it, and how many sends included it. A topic that left only inside a private overlap check has no readable value and shows no values.
   - Kept on your phone: topics the plan's skills use that never left, then the permissions whose data stayed (calendar, exact location, photo library).
   - Items under no topic (the agent card) are listed once.
4. **"How this came together" spans the plan.** `PlanTimeline` gathers the plan's first interaction, every owner link (the rule of `Collection<Interaction>.chain(from:)`), and every friend's request grouped by an accepted `chainedFrom` hint (ADR 0240), in start order. Opened from any member, it is the same plan's timeline. Each entry carries the skill's name, its origin (the plan, an owner link with its trigger and `optedInAt`, or a friend), state, times, artifacts, and, for a waiting after-plan-ends link, when it starts. Hand-offs such as Add to Calendar are not interactions; lane A adds them to the rendered timeline.

## Consequences

- The test `theEgressLogEqualsWhatTheConsentSheetShowed` wires the real policy (a test-only dependency) and checks the log against the sheets; the Swap photos end-to-end test does the same for a time-triggered link.
- Rendering the values in plan words ("after 7 tonight", "nearby") is lane A's, from typed `IssueValue`s.
- If the app ever installs a second observer (lane G's `InMemoryAuditLog`), it needs a fan-out observer, since `Outbox` takes one. That is a small app-side type.

## Sources

- ADR 0011 decisions 5 and 7; ADR 0012 decision 7; ADR 0014
- Mockup "Plan detail · skill chain + what left your phone"
- `Packages/StarlingCore/Sources/StarlingCore/Outbox.swift` (`OutboxObserver`), `Packages/StarlingPolicy/Sources/StarlingPolicy/Policy.swift` (`disclosure(for:)`)
- `Packages/StarlingChaining/Sources/StarlingChaining/EgressRecorder.swift`, `WhatLeftYourPhone.swift`, `PlanTimeline.swift`, and their tests
