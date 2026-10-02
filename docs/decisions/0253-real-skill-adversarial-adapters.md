# ADR 0253: Test merged services at authenticated and persistent boundaries

- Status: Proposed
- Date: 2026-10-01
- Owner: P15-F

## Context

The contract pass in ADRs 0250 to 0252 cannot establish how a real service binds
peer messages, recovers state, or hands artifacts to a later skill. Main now
contains Pick a place, Find a time, StarlingChaining, Swap photos, and the shell.
The app wiring is a follow-up. Issue #49 separates those evidence boundaries.

## Decision

1. Add only test dependencies and F-owned adapters. Use real SkillService,
   Policy, Outbox, ConversationLedger, planner, scheduler, and EgressRecorder.
   Script model and calendar data. Venue searches use a local identifier-based
   provider; no test requests a system permission or live network search.
2. Where peer identity matters, use Simulation(security: .secureChannel). Keep
   its original Inbox as the sole consumer and forward already accepted
   messages through AgentBehavior. The service Outbox shares that agent's
   channel. Bootstrap cards are actual hello envelopes accepted by the Inbox.
3. Inject protocol clocks and gates. Compare exclusion and silence before and
   at the same deadline. Suspend retirement writes to verify event ordering;
   throw them to verify failure reporting. Do not create machine load.
4. Apply service events through a small test coordinator and real Interaction
   state machine. This proves service behavior, not the app's settings,
   permission, or consent orchestration. Keep those adapters pending in #49.
5. Test the actual recorder's recovery with retained journal state, then test
   FileConversationLedger and FileSentSequenceStore separately on temporary
   files. Retained in-memory state is not a claim of filesystem crash durability.
6. Reproduce defects before marking them known. File an issue with exact input,
   baseline, expected result, observed result, owner, and runnable test name.
   Wrap only the failing assertion in unconditional withKnownIssue, so a fix
   that makes it pass demands removal of the marker. Do not edit another lane's
   implementation. The shell's fixed #46 prefill cases return to ordinary tests.
7. A shorter roster must remain shorter across the real service-to-planner
   handoff. Test actual produced attendees, the updated parent, and the next
   suggestion. Check timeline hints against final plan membership separately.

## Consequences

The initial integration pass found missing query binding in both organizer services,
missing version validation in an open place conversation, failed place admission
writes that do not stop answers, and two chain membership defects (#63 to #68).
Passing component contracts had not established those properties. PRs #70 to #72
fix all six findings; on main `c76fb24`, the original reproductions pass ordinary
assertions, including the shorter-roster handoff. The seven known-issue markers
are removed. Genuine query IDs and a compatible proposal still advance, while
failed admissions retire without any venue lookup, interaction, or send. The remaining
Down for and app-wiring cases stay open rather than being represented by fakes.

The calendar, Maps, picker UI, and real-model measurements still need their
opt-in or device checks. ADR 0231's venue containment is supported by real
service and PickAPlaceCopy tests: hostile names are displayed but removed from
proposal model facts. This does not approve exposing venue names to a real model.

## Sources

- ADRs 0011, 0012, 0019, 0020, 0021, 0200, 0201, 0205, 0220 to 0222,
  0230 to 0232, and 0240 to 0242.
- `Packages/Skills/PickAPlace/Sources/PickAPlace/` and
  `Packages/Skills/FindATime/Sources/FindATime/` at main `fde141f`.
- `Packages/StarlingChaining/Sources/StarlingChaining/` and
  `Packages/Skills/SwapPhotos/Sources/StarlingSwapPhotos/` at main `fde141f`.
- `App/Features/Sources/StarlingFeatures/FileConversationLedger.swift`,
  `FileSentSequenceStore.swift`, and `PairingModel.swift` at main `fde141f`.
- [Integration list](https://github.com/oliverrowebardeen/starling-ios/issues/49).
