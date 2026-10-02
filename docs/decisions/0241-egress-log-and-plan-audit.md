# ADR 0241: The egress log and the plan's audit

- Status: Proposed
- Date: 2026-10-01
- Owner: P15-E (Chaining and audit)

## Context

ADR 0011 decision 5: the egress log uses the consent sheet's `DisclosedItem`s, recorded by an `OutboxObserver` after each successful send, so "What left your phone" cannot disagree with what the owner approved. The plan detail mockup shows "How this came together" (each skill in the plan, with times, and Swap photos waiting "After 10:30 PM") and "What left your phone" as two lines: Shared ("Boba, after 7 tonight, nearby") and Kept on your phone ("Budget, exact location, calendar").

`OutboxObserver.outbox(didSend:context:decision:)` receives the policy's decision. A send that needed consent carries the sheet's `Disclosure`. A send the policy allowed without a sheet carries `.allow`, which has no items. Lane G's `DeterministicPolicyEngine.disclosure(for:)` computes the items for any message, but StarlingChaining depending on StarlingPolicy is a sideways dependency that needs the Orchestrator's approval (ARCHITECTURE section 1). Core v2.1 resolved this by having Outbox pass the items to its observer.

ADR 0011 decision 7 makes the lifecycle coordinator the only writer of interactions, and `InteractionStore` has no atomic update, so a second writer could lose an update.

## Decision

1. **`EgressRecorder` is the `OutboxObserver`.** After each send the transport accepted, it records an `EgressRecord` (completion time, recipient, items, the envelope's ID) on the interaction that owns the envelope's conversation. The items are what Outbox passes as `disclosed` (Core v2.1, at this lane's request):
   - `needsConsent`: the sheet's own items, exactly.
   - `allow`: the policy's own list, from `PolicyEngine.disclosedItems(for:)`, which `DeterministicPolicyEngine` answers with `disclosure(for:)`. `ChainedFromPolicy` passes the wrapped policy's answer through.
   - Declined, denied, cancelled, and failed sends are never reported by Outbox, so they are never recorded.
   - A link-level send with no skill (a `hello`) that no interaction owns is counted as unattributed. The policy's own audit log still has every send.
   - A send that carries a skill always belongs to an interaction, even one the coordinator has not created yet: a skill can announce an incoming request and send its automatic answer before the coordinator consumes the announcement (review of lane A's PR #73). Its record stays pending and journaled, its conversation unconfirmed, until the interaction exists; it is retried on `interactionArrived(conversation:)`, on the next send, and after a restart. It is never dropped as unattributed, so What left your phone cannot claim its topics were kept.
   - A send the policy could not explain (`disclosed` is nil) is recorded with `itemsUnknown`, so it still shows and the audit knows it cannot vouch for that interaction (`Interaction.egressIsKnown` is false).
   - Every send stays unresolved from the moment Outbox reports it (tracked before the recorder's first suspension) until its own record is on the interaction. Unresolved sends are retried oldest first, on each new send and whenever the app calls `retryPending()`; a send being written is skipped by a concurrent retry, and nothing is dropped from the unresolved set while a retry runs. The retry is safe because `Interaction.record` ignores a record for an envelope already recorded. At most 256 are kept in memory; past that the oldest is dropped and its conversation stays unconfirmed. `unconfirmedConversations` names every conversation with an unresolved send.
   - **The uncertainty survives a crash or restart** (ADR 0021 decision 4). An `EgressJournal`, which lane A keeps on disk, gets each send's entry in `OutboxObserver.outbox(willSend:...)`, before the transport takes the envelope, marked not yet sent and holding its items. If the journal cannot write it, `willSend` throws and Outbox sends nothing. `didSend` marks the entry sent and records the send; the entry is removed only after the record is on its interaction. At launch, `recover()` writes any entry still marked unsent as an `itemsUnknown` record on its interaction, since it may or may not have left, and retries the sent ones. If the journal cannot be read, `journalUnreadable` tells the app to claim nothing stayed on the phone.
2. **The coordinator writes.** The recorder writes through `EgressSink`, which lane A's coordinator implements, so egress records go through the same serialized writer as lifecycle events. `StoreEgressSink` (read, record, save) is for tests and tools.
3. **"What left your phone" is computed, not stored.** `WhatLeftYourPhone` reads the egress logs of a plan's interactions and their skills' descriptors:
   - Shared: each topic that left, its distinct values in the order they first left, who received it, and how many sends included it. A topic that left only inside a private overlap check has no readable value and shows no values.
   - Kept on your phone: topics the plan's skills use that never left, including where you are and calendar details (ADR 0019), then the permissions whose data stayed (calendar, location, photo library).
   - Items under no topic (the agent card) are listed once.
   - "Kept" claims that something never left, so it is made only from interactions whose log is known to be complete. An interaction whose `egressIsKnown` is false, or whose conversation the recorder lists as unconfirmed, is listed in `unconfirmed`; its topics and permissions are left out of Kept, even when a confirmed interaction also uses them, and the app says it could not confirm everything that left during it. Exposure comes only from the exact `SkillRef` that ran: if this build registers another version, or none, a confirmed interaction claims nothing kept of its own, and an unconfirmed one withholds the whole Kept list, since it could have sent anything. What its log does show stays under Shared.
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
