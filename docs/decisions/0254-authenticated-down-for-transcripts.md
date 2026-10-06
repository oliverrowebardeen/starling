# ADR 0254: Verify one-to-one quiet asks through authenticated transcripts

- Status: Proposed
- Date: 2026-10-01
- Owner: P15-F

## Context

PR #56 merged Down for at `8c52f25`. ADR 0011 amendments 16 and 17 replace
quiet group reveal with independent pair requests and require a starter's pass
to keep its proposal delivery schedule. Issue #49 needs real-service evidence
for these rules, beyond the Core contracts and lane B's own Loopback tests.

## Decision

1. Add a test-only DownFor dependency and use the real DownForService, Policy,
   Outbox, and ConversationLedger over Simulation(security: .secureChannel).
   Reuse the sole Inbox relay. Bootstrap support cards cross that channel;
   link availability is taken from the already established authenticated mesh.
2. A scripted AgentModel records matching calls and can invent a candidate.
   Assert that hard limits and candidate membership still govern the answer,
   and that peer instructions never call intent interpretation or decision
   routing. This tests containment, not a real model's injection resistance.
3. Compare an excluded quiet asker with a phone that is not down; both get
   no response, model call, or consent. Keep positive controls with real pair
   plans. Hold another friend's consent while the observed pair completes.
   Pair terms and audits must contain neither other friends nor private chips.
4. Compare starter pass, silence, and another friend's interest using the
   configured delivery intervals. After PR #86, delivery and invitation windows
   honor SkillClock. This authenticated fixture supplies real sleeps for short
   protocol timers, freezes long expiry timers, and reports bounded tolerances.
   Lane B's service and coordinator tests separately control virtual time;
   do not claim that this wire fixture has exact deterministic clock coverage.
5. Isolate a lost final resend with an injected willSend suspension, without
   machine load or packet loss. The observed defect (#76) was fixed by PR #86.
   Its exact-count assertion is now ordinary: all four scheduled proposals
   must arrive. The other comparisons still check bounded prefixes; lane B's
   virtual-time test verifies the complete coordinator schedule. The original
   lost resend alone did not establish a reliable privacy inference.
6. Retain request records and the same conversation ledger across service
   replacement. Verify candidate and PSI limits, retirement of both a member's
   request and the starter's conversation, and no card or response on replay.
   The ledger fixture holds multiple concurrent retirements without losing
   continuations. This is retained-state testing, not a phone crash claim.
7. Exercise app wiring through ADR 0255: composition, consent cancellation,
   mode/audience parsing, disk stores, and coordinator-owned audit attribution.
   PRs #82 and #86 add the native starter-pass transcript through the coordinator.

## Consequences

The real service runs under every eligible topic set to Never, with budget and
place chips kept local. A group requires Invite and People consent; accepting
its exact offered terms works with the invitee's People set to Never. Mode,
skill version, query, proposal, and confirmation attacks are tested on actual
authenticated envelopes. A current denied acceptance ends blockedByPrivacy;
a late denial cannot replace withdrawal. The earlier six findings remain
ordinary regression assertions after PRs #70 to #72. A real quiet plan also
feeds ChainPlanner and PickAPlaceService, with a hostile venue name, explicit
owner consent, and only the parent plan's friend as recipient.

Phase 1 Down integration tests stay until the app migration and Orchestrator's
facade-removal step in ADR 0211. Adding the new service tests is not permission
to remove another lane's code or the still-used legacy test infrastructure.

## Sources

- ADRs 0011 amendments 16 and 17, 0019, 0020, 0021, 0210 to 0212, and 0253.
- `Packages/Skills/DownFor/Sources/DownFor/` at `8c52f25`, especially
  DownForService+Delivery.swift, DownForService+Steps.swift, and RequestStore.swift.
- `Packages/Skills/DownFor/Tests/DownForTests/PrivacyTranscriptTests.swift`
  and `ReviewRegressionTests.swift` at `8c52f25`.
- `docs/requests/P15-B.md` at `8c52f25`.
- PR #86 at `29e58fb`, including ADR 0210 decision 13 and the service and
  coordinator delivery tests.
- Integration list (#49)
  and lost final resend (#76).
