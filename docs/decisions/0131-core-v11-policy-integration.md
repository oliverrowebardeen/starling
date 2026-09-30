# ADR 0131: Use Core v1.1 egress context and audit callbacks

- Status: Proposed. Implemented in PR #10.
- Date: 2026-09-30
- Owner: G, Policy and consent
- Supersedes the registration, audit-wrapper, and consent-lifecycle workarounds in ADR 0130

## Context

Core v1.1, merged in `c4debe0`, resolves the interface gaps that required local state and an Outbox wrapper in the initial G implementation. The new contracts were verified directly against the merged Core source before this migration. The existing disclosure-rule and self-declared-locality decisions from ADR 0130 remain applicable.

## Decision

1. Read answered values from `Answer.issue` and `Answer.acceptable`. Remove query registration and lookup state.
2. Read every PSI step's provider and complete typed inputs from `OutboundMessage.context.psi`. The sender supplies this through `Outbox.send(..., context:)`; nothing is registered or cached in policy. Missing context denies the step. Validate each IssueValue because the context dictionary does not validate itself. Non-private providers require consent showing all inputs; never rules still deny. Private providers retain issue markers without raw input values.
3. With no context state remaining, make `DeterministicPolicyEngine` an immutable Sendable struct. The paired-peer store remains an asynchronous dependency for automatic-sharing checks.
4. Make `AuditLog` an `OutboxObserver` and install the in-memory log directly on Core Outbox. Remove the wrapper. The callback summarizes only after successful transport handoff. It uses the answer's issue and PSI context to record issue/value-kind summaries, without retaining raw context or consent values.
5. Rely on Core's cancellation checks and policy re-evaluation after consent. Remove G's cancellation workaround and obsolete app guidance. Integration tests cover cancellation and a changed rule while consent is pending.
6. Treat `IssueKey.downLevel` as interest. Owner disclosure rules apply normally; default consent remains required. The consent row says whether the owner said `down` or `maybe`. F controls the mutual-match stage at which it sends this acceptance term.

## Consequences

F and H use concrete Core Outbox with an audit observer and per-send PSI context. There are no registration limits, cleanup obligations, or shared-interface changes in G. Core's new currencyMismatch hard-limit reason does not change G's egress decisions; G has no switch over LimitViolation reasons. Core Disclosure still lacks exact card/control/provider metadata, so request 4 remains open and nonblocking, with honest category markers as before. Device checks remain pending owner execution.

## Sources

- [Core v1.1 merge](https://github.com/oliverrowebardeen/starling-ios/commit/c4debe0).
- [Core policy and local context contracts](../../Packages/StarlingCore/Sources/StarlingCore/Policy.swift).
- [Core Outbox, observer, re-evaluation, and cancellation](../../Packages/StarlingCore/Sources/StarlingCore/Outbox.swift).
- [Core Answer.issue](../../Packages/StarlingCore/Sources/StarlingCore/Messages.swift).
- [Core IssueKey.downLevel](../../Packages/StarlingCore/Sources/StarlingCore/Values.swift).
- [Core currencyMismatch hard-limit handling](../../Packages/StarlingCore/Sources/StarlingCore/HardLimits.swift).
- [ADR 0130](0130-deterministic-disclosure-and-consent.md), unchanged policy and privacy rationale.
