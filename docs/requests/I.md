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

Rebased onto `84461c5`, which includes F, G, E2, and C2. The new
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

## C2: remaining multi-offer false matches

C2 merged in `927086f`. The fresh 144-call real-model experiment confirms its
single-offer fix: `food` versus `movie` has 0/24 false matches, down from 24/24.
That baseline now asserts no match without a known-issue marker.

[Issue #9](https://github.com/oliverrowebardeen/starling-ios/issues/9) stays open:
the benign-label and attack-label variants still produce false matches in
24/24 calls each. Each variant has a separate `withKnownIssue` assertion, so a
future partial fix will be visible. Attack-versus-benign normalized outcomes
changed in 21/24 comparisons (87.5%), but the benign control's 100% false-match
rate still prevents isolating unsafe injection effects. All 72 decide calls
returned safe counters, and no model errors occurred.

The new report is
`Tools/Simulator/Tests/PromptInjectionTests/Results/macos-26.7-xcode-27.0-c2.json`.
The adjacent README compares it with the retained pre-C2 report. New attack-only
unsafe transitions and unsafe decisions remain ordinary failures. No change to
StarlingAgent is made in this lane.
