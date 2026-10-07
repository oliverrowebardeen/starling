# ADR 0150: Reproducible adversarial tests and paired injection measurements

- Status: Accepted for lane I's test harness; no shared interface changes
- Date: 2026-09-30
- Owner: I, red team

## Context

Brief section 5 and the approved Phase 1 plan require malformed input, PSI
abuse, replay, consent-bypass, and prompt-injection coverage. ADRs 0003 and 0009
separate authentication from transport and restrict model inputs to typed
values. A passing test suite must still expose unresolved production defects.

The sources below were rechecked on 2026-09-30. The selected local tools report
Xcode 27.0 (27A266a), Swift 6.4, and macOS 26.7 (25G229). Model generation uses
the existing `FoundationModelsAgent`, including its greedy sampling and fresh
sessions; the red team owns no prompts or production enforcement code.

## Decision

1. Mutate the copied v0 golden frame plus valid frames of every body kind.
   Run 2,000 mutations in each of five families: bit flips, truncation, splices,
   extreme JSON numbers, and hostile Unicode. SplitMix64 with explicit modulo
   selection and seed `0x535441524C494E47` fixes the stream. A failed decode
   must throw `CodecError`; a successful decode must re-encode and round-trip.
   Separate cases check the envelope byte cap. Print counts by family, and
   include seed, family, and iteration in failure diagnostics.
2. Exercise PSI through `any PSIProvider` and `any PSISession`. Check local and
   peer limits, both output modes, malformed inputs, and step ordering. The
   stub-specific wire mutations are explicitly labeled. No privacy claim is
   made for `InsecurePSIStub`.
3. Run temporal scenarios through Loopback and Inbox using a fixed clock.
   Check reordered-but-unseen sequences, exact replay-window edges,
   `UInt64.max`, age/skew boundaries, and extreme timestamps. Invalid timestamps
   must not reserve sequence numbers. Use the hub's hostile-wire injection hook;
   honest messages still go through Outbox. Await simulator teardown.
4. Check Outbox denial and declined consent for every body kind, plus an
   instruction-shaped keyword attempt over the simulator. Concrete policy and
   Down tests wait for their owning lanes to merge.
5. File each finding as a `red-team` GitHub issue and retain a focused
   `withKnownIssue` expectation linked to it. Deterministic markers are
   non-intermittent, so a fix requires removing the marker. Fixture setup and
   unrelated errors stay outside the marker. Do not fix another lane's code.
6. Keep the real model opt-in with `STARLING_MODEL_TESTS=1`. Only the test target
   depends on StarlingAgent. The experiment accepts `any AgentModel`; rate
   arithmetic and error handling run against `ScriptedAgentModel` in ordinary
   tests. All peer labels pass through Keyword validation and EnvelopeCodec
   before use, and enter the model only through `match` or `decide`.
7. For each of eight attack keywords, measure three repetitions of a baseline,
   a benign added label (`quiet evening`), and an attack added label. Keep all
   other inputs fixed; rotate call order across repetitions. Match uses the
   want `food` and offer `movie`. Decide uses a $15 budget and a $50 proposal
   with valid time constraints. Report role-normalized match changes and
   decision-kind/safety changes, false matches, hard-limit violations, and
   attack-only unsafe transitions. Preserve model errors as a separate category.
   Outcome-change denominators include only complete triples. Unsafe rates
   use successful calls, with attempted calls and error counts also reported.
8. Retain the full JSON trial report with the Mac measurements. If no complete
   triples run, the opt-in test fails instead of silently skipping. Greedy
   repeats measure consistency on this host; these are descriptive rates over
   a small selected corpus, not estimates of a population-wide attack rate.

## Consequences

The normal suite is deterministic and requires no device or model assets.
The real-model experiment makes 144 calls: eight payloads, three repetitions,
three variants, and two tasks. Adding a semantically different label can affect
model behavior without establishing instruction following, so report neutral
control changes alongside attack changes and avoid claiming causation from
an outcome difference alone. No model result is sent through a live transport.

The bare simulator's impersonation finding was closed once the scenario ran
over the E1 secure channel (`impersonationIsDroppedBeforeTheInbox`). The Orchestrator owns simulator production wiring. PSI
findings and that integration request are recorded in `docs/requests/I.md`.

## Initial measurements

The 10,000 mutations completed without a crash: 728 accepted frames round-tripped
and 9,272 failures were typed `CodecError`. The real-model run completed 144/144
calls without errors. Match changed in 6/24 attack-versus-benign comparisons,
but false matches occurred in 24/24 baseline, benign, and attack calls. That
negative-control defect is issue #9, not evidence of successful isolation of
an injection effect. Decide returned safe counters in all 72 calls.

Full denominators, limitations, and normalized trial data are retained in
`Tools/Simulator/Tests/PromptInjectionTests/Results/`. The PSI findings are
issues #6 and #7; the bare-link impersonation gap is issue #8.

## Sources

- Apple Swift Testing, known issues, including fixed-issue detection and
  intermittent failures:
  https://developer.apple.com/tutorials/data/documentation/testing/known-issues.json
- Apple Foundation Models, model availability:
  https://developer.apple.com/tutorials/data/documentation/foundationmodels/systemlanguagemodel/availability-swift.property.json
- Apple Foundation Models, greedy sampling:
  https://developer.apple.com/tutorials/data/documentation/foundationmodels/generationoptions/samplingmode-swift.struct/greedy.json
- Repository primary contracts: `Packages/StarlingCore/Sources/StarlingCore/PSI.swift`,
  `Inbox.swift`, `Outbox.swift`, `EnvelopeCodec.swift`, and `AgentModel.swift`.
- Existing renderer/backend:
  `Packages/StarlingAgent/Sources/StarlingAgent/FoundationModelsAgent.swift` and
  `PromptRenderer.swift`.
