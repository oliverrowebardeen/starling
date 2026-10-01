# Lane I requests

## Resolved in Core v1.1: PSI stub input validation

Core v1.1, merged in `c4debe0`, fixes both findings in Orchestrator-owned
`Packages/StarlingCore/Sources/StarlingFakes/InsecurePSIStub.swift`. Issues #6
and #7 are closed:

1. [Issue #6](https://github.com/oliverrowebardeen/starling-ios/issues/6): the
   initiator now rejects an intersection or cardinality above `maxPeerSetSize`.
   The raw reply list is bounded before deduplication, including the 336-copy
   digest attack with a peer limit of 1.
2. [Issue #7](https://github.com/oliverrowebardeen/starling-ios/issues/7): the
   responder now requires 32-byte SHA-256 digests. Lengths 0, 1, 31, 33, and 64
   throw `PSIError.malformedMessage`.

Reproductions live in `Tools/Simulator/Tests/ScenarioTests/PSIAbuseTests.swift`.
The tests now assert the typed errors directly, without `withKnownIssue`
markers. Cardinality replies above the peer bound, including `Int.max`, now
expect `PSIError.peerSetTooLarge`. The Answer fixture supplies its `.activity`
issue for the v1.1 initializer. Markers for #8 and #9 remain unchanged.

## E1 and Orchestrator: secure simulator wiring

[Issue #8](https://github.com/oliverrowebardeen/starling-ios/issues/8) tracks the
existing impersonation gap. `SimulatorKit.SimulatedAgent` currently constructs
a bare `LoopbackTransport`. Merging E1 alone cannot make that scenario secure.

When E1 lands, either expose secure transport construction in `SimulatorKit`
or direct lane I to add a test-only secure stack using E1's public API. Keep the
raw-link case as a labeled negative control, and make the Phase 1 impersonation
acceptance test exercise the actual secure channel. Lane I cannot edit
`Tools/Simulator/Sources/` under its ownership rules.

## Completed: F and G integration

Rebased onto `777de46`, which includes F, G, and E2. The new
`Tools/Simulator/Tests/DownIntegrationTests/` target exercises the public
`DownNegotiator` and `DeterministicPolicyEngine` through Inbox and Outbox over
Loopback, with the real audit observer. Its 15 tests include 22 parameterized
cases covering mutual and one-sided interest, three-peer overlap, disclosure
rules, consent decline and withdrawal, partitions, malicious PSI, replay,
timestamp rejection, forged acceptances, and hostile model output.

These scenarios found no new F or G defect. They use scripted models and
fixture paired records; they do not replace the secure-channel acceptance
scenario tracked by #8. Method and limits are in
[ADR 0151](../decisions/0151-down-policy-integration-tests.md).

## C2: matching negative controls

[Issue #9](https://github.com/oliverrowebardeen/starling-ios/issues/9) records
`food` versus `movie` matching as equivalent in 24/24 real-model baseline calls.
The benign and attack variants also produced false matches in 24/24 calls each.
Attack-versus-benign normalized outcomes changed in 6/24 comparisons, but the
100% baseline false-positive rate prevents isolating unsafe injection effects.
Decide returned safe counters in all 72 calls. There were no model errors.

Please add unrelated-pair evaluation and correct the matcher in StarlingAgent.
The full rates and 48 trial triples are in
`Tools/Simulator/Tests/PromptInjectionTests/Results/`. Rerun the opt-in experiment
after C2 lands. Its baseline assertion links to #9 with `withKnownIssue`; new
attack-only unsafe transitions and unsafe decisions remain ordinary failures.
Per the C2 relay, once the Orchestrator confirms its merge, assert the corrected
baseline normally and retain #9 markers only on the benign-label and
attack-label variants that still fail. The F/G integration update leaves the
experiment and its markers unchanged.
