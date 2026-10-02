# ADR 0251: Test Core v2.1 privacy and audience boundaries without claiming service enforcement

- Status: Accepted for P15-F tests only
- Date: 2026-10-01
- Owner: P15-F, red team
- Extends: ADR 0250

## Context

Core v2.1 (`753ddcf`, PR #57) changes the approved privacy contract. A Never
value stays on the phone, but a subset of a peer's own candidates can leave as a
yes/no answer. New send modes require envelope version 2. Audience exclusion
must be undetectable, and declined sends must not reveal themselves in sequence
gaps. ADR 0011 amendments 13 to 15 assign lifecycle responsibilities explicitly.

## Decision

1. Migrate every P15-F skill envelope to an explicit mode, preserving old v0
   attack vectors. Test retired v1 and invalid/missing modes at both codec and
   Inbox boundaries, with the valid same-sequence message after each rejection.
2. Pin audience precedence to ADR 0020 with expected participant lists, including
   explicit picks overriding standing rules and exceptions overriding
   alwaysInclude. Test restored AudienceBook data, unsupported friends, and
   unknown groups. Real recipient traffic and inbound timing symmetry remain
   service integration cases in issue #49, not properties of the resolver alone.
3. Test seven yes/no value shapes through the real policy, Outbox, and audit
   callback under all three privacy choices. Compare exact candidate values,
   including venue coordinates and currency. Missing context, wrong issues, and
   values absent from candidates must not bypass Never. Keep on-device versus
   cloud consent behavior explicit.
4. Treat answering context as trusted local provenance, as Core specifies.
   Query has no peer, conversation, or message ID, so a policy test cannot prove
   that a service selected the right query. Likewise the 16-candidate oracle
   budget is service state. Record both as required integration checks, with
   stale sends and cross-conversation attempts, instead of inventing a fake
   service that simply enforces the expected answer.
5. Exercise denied, declined, and cancelled sends between two ordinary-no
   frames. Assert no transport/audit entry for the refused sends and consecutive
   sequence numbers on the two observed frames. This tests Outbox behavior;
   the real service must still map a Never-caused refusal to noOverlap.
6. Test sequence restart with a shared SentSequenceStore and a backward clock,
   then test exhaustion and failed persistence. Test consentCancelled at every
   suspended step, privacy denial before planning, and planned-state immunity.
   Core cannot identify stale revisionless denials; services must drop those.
7. Keep audit uncertainty visible. An observer with no disclosed items produces
   an unknown record, not a claim that nothing left. Replayed record writes
   identified by MessageID cannot silently change that record.

## Consequences

The ordinary suite stays deterministic and device-free. No real-model call is
added. It uses the merged primary source APIs and leaves other lanes' code
untouched. Passing this suite is evidence for Core and the components it calls,
not for a future app coordinator or skill implementation. PR #50 stays draft
until the Orchestrator requests its integration passes.

## Sources

- [Privacy semantics](0019-never-stays-on-the-phone.md).
- [Send modes and audience](0020-send-modes-and-audience.md).
- [Lifecycle responsibilities](0011-one-lifecycle-and-interactions.md).
- [Core answering context and subset check](../../Packages/StarlingCore/Sources/StarlingCore/Policy.swift).
- [Outbox numbering, consent, and observer](../../Packages/StarlingCore/Sources/StarlingCore/Outbox.swift).
- [Audience resolver](../../Packages/StarlingCore/Sources/StarlingCore/Audience.swift).
- [Real policy](../../Packages/StarlingPolicy/Sources/StarlingPolicy/Policy.swift).
- [Integration cases](https://github.com/oliverrowebardeen/starling-ios/issues/49).
