# Lane I requests

## Orchestrator: PSI stub input validation

The public `PSIProvider` tests reproduce two failures in Orchestrator-owned
`Packages/StarlingCore/Sources/StarlingFakes/InsecurePSIStub.swift`:

1. [Issue #6](https://github.com/oliverrowebardeen/starling-ios/issues/6): the
   initiator accepts an intersection or cardinality above `maxPeerSetSize`.
   It also accepts 336 copies of one reply digest with a peer limit of 1.
   Bound the raw reply list and cardinality by the configured peer limit.
2. [Issue #7](https://github.com/oliverrowebardeen/starling-ios/issues/7): the
   responder accepts digest lengths 0, 1, 31, 33, and 64. Require 32-byte
   SHA-256 digests and throw `PSIError.malformedMessage` for malformed entries.

Reproductions live in `Tools/Simulator/Tests/ScenarioTests/PSIAbuseTests.swift`.
The failing expectations use non-intermittent `withKnownIssue` markers linked
to those issues. No shared interface change or production workaround was made.
Corrected behavior will require removing the corresponding marker.

## E1 and Orchestrator: secure simulator wiring

[Issue #8](https://github.com/oliverrowebardeen/starling-ios/issues/8) tracks the
existing impersonation gap. `SimulatorKit.SimulatedAgent` currently constructs
a bare `LoopbackTransport`. Merging E1 alone cannot make that scenario secure.

When E1 lands, either expose secure transport construction in `SimulatorKit`
or direct lane I to add a test-only secure stack using E1's public API. Keep the
raw-link case as a labeled negative control, and make the Phase 1 impersonation
acceptance test exercise the actual secure channel. Lane I cannot edit
`Tools/Simulator/Sources/` under its ownership rules.

## F and G integration follow-up

The v1-freeze tests exercise Inbox and Outbox with Loopback and policy/consent
fakes. After F and G merge, the Orchestrator should request the final lane I
pass against their concrete implementations: one-sided and reordered exchanges,
no false notifications, hard-limit enforcement, and consent denial. The current
tests do not claim that the future Down state machine or policy engine passed.

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
