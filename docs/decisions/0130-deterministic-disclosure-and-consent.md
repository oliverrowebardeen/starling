# ADR 0130: Deterministic disclosure and explicit consent

- Status: Implemented for review under the approved Phase 1 G mandate
- Date: 2026-09-30
- Owner: G, Policy and consent

## Context and verified sources

Brief 3.5 requires deterministic egress decisions, and 3.7 requires disclosure of shared fields and honest model-locality claims. The approved lane plan requires owner disclosure rules, the on-device setting, non-private PSI consent, and a local audit log.

Apple's current App Review guideline 5.1.2(i), re-read on 2026-09-30, requires disclosure of sharing destinations and explicit permission for sharing personal data with third parties, including third-party AI. This supports requesting consent for cloud and unknown recipients. It does not establish that a peer's claimed model location is verifiable or guarantee review approval. Core's `LocalityEvidence` currently contains only `selfDeclared`.

The frozen wire format omits the issue from Answer and the provider and semantic inputs from PSIFrame. Disclosure supports IssueValue and category markers, rather than arbitrary card/control metadata. Core Outbox checks policy and consent before sending but exposes no successful-send callback.

## Decision

1. Ship `DeterministicPolicyEngine` as an actor with immutable reviewed owner rules and bounded per-conversation context. An unspecified issue requires consent. Conflicting duplicate rules use the strictest action. A never rule denies before consent.
2. Automatic sharing under `allowOnDevicePeers` requires a matching paired-peer store entry and a recipient card declaring on-device processing or no model. A rule-based peer with no model is accepted because it declares no remote model use. Missing cards and cloud declarations require consent unless on-device-only mode is enabled, in which case non-hello messages are denied. Hello remains available to exchange cards without bootstrapping deadlock.
3. Compute every owner issue/value for proposals, counters, acceptances, queries, and answered answers. Register received query issues against both peers, conversation, and query ID. Never guess an issue from the value type. Control-only messages carry no owner IssueValues; card and opaque PSI metadata use category markers.
4. Require trusted local registration of every PSI frame, scoped to its exact bytes, peer, and conversation, using the actual provider descriptor and complete typed local inputs. Missing context denies. Non-private providers disclose all inputs and require consent for every step; never rules still deny. Private providers retain protected issue keys but omit raw input values. These are provider declarations, not a new cryptographic privacy claim.
5. Bound the context registry to 256 entries, reject conflicting replacements and overflow, and expose conversation cleanup. This avoids silently losing live issue bindings. No owner constraints or model are consulted to decide egress.
6. Provide plain consent presentation values retaining the exact DisclosedItems. Always label known model locality as self-declared and unverified; describe missing cards as unknown. List the general protocol metadata that also leaves the phone and honestly label markers whose exact fields cannot fit Core Disclosure.
7. Provide `AuditLog`, bounded `InMemoryAuditLog`, and `AuditedOutbox`. Append summaries after Core Outbox succeeds, never at policy evaluation or consent approval. Retain only recipient, message ID, completion time, message kind, issue keys, and value kinds. A successful handoff is not proof of peer receipt. No raw values or PSI payloads enter audit storage.

## Consequences and integration

- Production code depends only on Core; tests use Core fakes and the authorized Loopback test dependency. The selected toolchain was verified locally as Xcode 27.0 (27A266a), Swift 6.4. Package language mode is Swift 6, with warnings treated as errors by `Tools/test-all.sh`.
- F must register incoming queries and outgoing PSI frames, then release context on completion. Registrations are trusted local provenance and cannot independently prove what arbitrary opaque bytes encode.
- H supplies the consent provider, binds recipient cards from the authenticated channel, and declines pending consent before replacing policy or removing trust. Current Core Outbox cannot revalidate policy after a suspended consent request.
- Audit coverage requires the wrapper. F's concrete Core Outbox dependency needs an Orchestrator-owned success observer or an approved wrapper integration. Direct Core Outbox calls remain policy-gated but are not audited.
- Exact card/control/provider metadata cannot fit the frozen Disclosure. Category markers are explicit, and the shared-model extension request is recorded rather than fabricating issue values. Audit summaries likewise do not infer answer or PSI issues absent from the wire.
- The requests in `docs/requests/G.md` are integration obligations, not changes to Core in this branch. Device behavior remains for owner verification.

## Sources

- [Apple App Review Guidelines, 5.1.2(i)](https://developer.apple.com/app-store/review/guidelines/#data-use-and-sharing), retrieved 2026-09-30.
- [Approved Phase 1 plan](../plans/phase-1-lane-plan.md), lane G mandate.
- [Core Policy and Disclosure contracts](../../Packages/StarlingCore/Sources/StarlingCore/Policy.swift).
- [Core message and locality contracts](../../Packages/StarlingCore/Sources/StarlingCore/Messages.swift).
- [Core PSI provider contract](../../Packages/StarlingCore/Sources/StarlingCore/PSI.swift), including whole-set treatment of non-private providers.
- [Core Outbox implementation](../../Packages/StarlingCore/Sources/StarlingCore/Outbox.swift), the sole egress gate.
- [ADR 0003](0003-message-layer-security.md), authentication belongs to the secure channel.
- [ADR 0006](0006-one-swiftpm-package-per-lane.md), package ownership and Swift 6.
