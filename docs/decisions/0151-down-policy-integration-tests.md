# ADR 0151: Exercise Down and policy together over Loopback

- Status: Accepted for lane I's test harness; no shared interface changes
- Date: 2026-09-30
- Owner: I, red team
- Extends ADR 0150's deferred concrete F/G coverage

## Context

Main at `777de46` includes the F Down implementation and G policy engine. Their
public contracts were verified against the merged repository source before
building this harness. The Phase 1 exit requires adversarial tests across the
composed exchange, including silence on failure and policy enforcement at egress.
Lane I owns test code, not the production simulator composition.

## Decision

1. Add a test-only `DownIntegrationTests` target with local dependencies on
   StarlingNegotiation and StarlingPolicy. Build each honest peer from the real
   DownNegotiator, DeterministicPolicyEngine, Inbox, Outbox, InMemoryAuditLog,
   and LoopbackTransport. Observe policy decisions through a delegating wrapper.
   Use only public APIs and await teardown of every event consumer.
2. Use ScriptedAgentModel for reproducible model outcomes, including hostile
   match pairs and unsafe counters. Pin the wall clock and time zone, shorten
   retry timers, and wait for the triggering message or consent state before
   asserting silence across a one-second interval. That exceeds the configured
   800 ms details deadline. Apply a one-minute time-limit trait to both suites.
3. Observe the wire independently through LoopbackHub. Require matched terms
   to pass Core's hard-limit check and have a peer acceptance of the same plan.
   Compare successful wire message IDs with the real audit observer's IDs.
   Refused consent and failed transport handoffs must not create audit entries.
4. Drive the malicious peer through its own Inbox, Outbox, and real policy.
   Use the hub injection hook only for exact replay and invalid timestamps,
   which a normal Outbox does not generate. Pairing records are fixtures and
   make no authentication claim about the bare link.
5. Exercise malformed and oversized PSI, an invalid opening step followed by
   a valid positive control, stale/future frames with maximal sequence numbers,
   forged acceptance IDs/terms/levels, repeated queries with instruction-shaped
   keywords, and invented or unsafe model output. Check both rejected attempts
   and subsequent valid exchanges where recovery is expected.
6. Preserve issue #8's existing impersonation marker until the Orchestrator
   wires the secure channel (since done: the scenario runs over it). Keep the existing opt-in model experiment and #9
   marker unchanged pending C2's merge. These deterministic integration tests
   measure protocol containment; they do not measure the real model's injection
   susceptibility or the app's device behavior.

## Consequences

The added 15 tests cover 22 parameterized cases without a device or real model.
Positive controls guard against a silent or disconnected harness satisfying
negative assertions. This pass found no new F or G defect. A later finding must
be filed as a red-team issue and retained as an issue-linked known failure,
without changing another lane's code.

The harness retains the non-private PSI stub, so consent must disclose its time
inputs even when ordinary typed issues are allowed for paired on-device peers.
Tests cover approved, declined, suspended, and withdrawn consent, but not the
app's presentation. The owner checklist remains the device handoff.

## Sources

- [ADR 0120: Down protocol](0120-down-negotiation-protocol.md).
- [ADR 0121: Model use and hard limits](0121-down-model-use-and-hard-limits.md).
- [ADR 0131: Core v1.1 policy integration](0131-core-v11-policy-integration.md).
- [Down public implementation](../../Packages/StarlingNegotiation/Sources/StarlingNegotiation/DownNegotiator.swift).
- [Policy implementation](../../Packages/StarlingPolicy/Sources/StarlingPolicy/Policy.swift).
- [Core egress gate](../../Packages/StarlingCore/Sources/StarlingCore/Outbox.swift).
- [Core ingress validation](../../Packages/StarlingCore/Sources/StarlingCore/Inbox.swift).
- [Lane I harness and assertions](../../Tools/Simulator/Tests/DownIntegrationTests/).
