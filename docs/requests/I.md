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
issue for the v1.1 initializer. The later #8 and #9 updates are recorded below.

## Secure impersonation regression for issue #8

[Issue #8](https://github.com/oliverrowebardeen/starling-ios/issues/8) tracks the
bare-link impersonation gap. PR #34, merged as `ebeef76`, exposes
`Simulation(security: .secureChannel)` over E1's SecureTransport, with independent
identity keys and fixture pins for each pair.

The `impersonation` scenario now uses secure mode, and its test has no known-issue
marker. It checks one additional secure-channel drop, no forged rejection in
Bob's accepted envelopes, and no Inbox drop. A genuine proposal from Alice then
uses the forged conversation's sequence zero and must arrive, with Alice's key
still proven. This checks that rejecting the forgery neither loses the live
session nor poisons Inbox replay state. Assertions do not assume seeded IDs.

Removing the marker first reproduced the original bare-link acceptance failure.
E1 merged in `24b37e9`, and this follow-up is rebased onto main at `ebeef76`,
with all merged Phase 1 scenarios and model tests retained. The fixed scenario
clock is preserved alongside secure mode. No SimulatorKit or Identity source
was edited, and #9's opt-in markers are unchanged.

## Completed: F and G integration

The F/G pass used `84461c5`, which includes F, G, E2, and C2. The
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
