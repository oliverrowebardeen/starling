# ADR 0250: Separate executable boundary tests from real-skill integration evidence

- Status: Accepted for P15-F test code only
- Date: 2026-10-01
- Owner: P15-F, red team

## Context

The Phase 1.5 mandate covers ADRs 0010 to 0018 and architecture rules 1 to 8.
The lane starts at `e3aa401`, which includes the Core v2 freeze `c07c036` but
no Phase 1.5 skill implementations or shared lifecycle coordinator. A fake
service records calls and emits supplied events. It cannot establish that a
production service denies an unsolicited start or handles OS permission denial.

## Decision

1. Keep reusable hostile venue names, keywords, and confusable nickname inputs
   in `Tools/Simulator/Scenarios/Phase15Attacks.swift`. Test only owned targets.
   Add the existing app Features package as a test-only dependency to exercise
   actual consent memory, roster formatting, and pairing-name behavior.
2. Test Core lifecycle rejection with whole-record equality, including after a
   Codable round trip, and restore records through `InMemoryInteractionStore`
   and `ScriptedSkillService`. Cover every consent resume step, overlapping
   requests, stale revisions, exhausted counters, and every final state. Label
   scripted permission-denial transcripts as contract fixtures, not OS tests.
3. Exercise every eligible Never topic across all four sample skill refs and
   the five typed egress body shapes through the real policy and Outbox. Check
   transport, consent, and observer counts. Follow every denial with the same
   payload under a permissive policy as a positive control. Compare encoded
   agent cards across privacy settings, not just descriptor counts.
4. Use `Simulation(security: .secureChannel)` for identity-sensitive traffic.
   Attach v2 metadata with a test-only Outbox over an existing simulated secure
   channel and fresh conversations; leave SimulatorKit unchanged. A delivered
   authenticated chain hint is expected. Only the later service/coordinator
   adapter can establish that it cannot start a skill or permission.
5. Inspect StarlingAgent's real deterministic prompt renderer with `@testable`
   import. Valid venue payloads must survive wire and artifact storage but
   appear only as a count in decision prompts. Instruction-shaped keywords are
   intentionally valid data; test hard-limit and policy containment. The existing
   model experiment remains opt-in. No deterministic test establishes real-model
   injection resistance or iOS model quality.
6. Keep issue #46's exact pairing-name expectation inside a non-intermittent
   `withKnownIssue`, with setup and positive controls outside it. A fix makes the
   marker fail so the test must be revisited. Keep every unimplemented real-skill
   scenario in issue #49 with its inputs and required observations. Do not mark
   those integrations as passing merely because a fake ignored a message.

## Consequences

The initial PR provides executable boundary coverage and an explicit integration
gate. F merges last and revisits issue #49 after A through E land. A fresh Inbox
accepts a recent old plaintext envelope because its replay window is in memory;
that documented limit makes restored lifecycle/service state essential. The
secure test does not claim to simulate a full process restart or disk failure.

No shared interface, production prompt, skill, UI, or security decision changes.
Hand-off UI, permission alerts, pair-symbol rows, copy, and Release presentation
remain device or owner-lane checks. The device checklist records their expected
behavior without implying execution.

## Sources

- [Core v2 lifecycle and amendments](0011-one-lifecycle-and-interactions.md).
- [Artifacts, venue names, chain hints, and roster](0012-artifacts-and-chaining.md).
- [Permissions and fallbacks](0013-just-in-time-permissions.md).
- [Global privacy topics](0014-global-privacy-topics.md).
- [Phase 1 adversarial method](0150-adversarial-test-method.md).
- [Core Interaction source](../../Packages/StarlingCore/Sources/StarlingCore/Interaction.swift).
- [Real prompt renderer](../../Packages/StarlingAgent/Sources/StarlingAgent/PromptRenderer.swift).
- [Apple Swift Testing known issues](https://developer.apple.com/tutorials/data/documentation/testing/known-issues.json), re-read 2026-10-01: a resolved non-intermittent known issue produces a failure until its marker is removed.
- Roster issue #46.
- Real-skill integration gate #49.
