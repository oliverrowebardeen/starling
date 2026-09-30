# StarlingPolicy

Deterministic policy, consent presentation values, and a local audit interface for the frozen Core v1 contracts. The production target depends only on StarlingCore. The transport dependency is test-only for the authorized Loopback acceptance tests.

## Policy composition

```swift
let policy = DeterministicPolicyEngine(
    ownerRules: reviewedRules,
    onlyOnDeviceAgents: true,
    pairedPeers: pairedPeerStore
)
let outbox = Outbox(transport: secureChannel, policy: policy, consent: consentProvider)
let audit = try InMemoryAuditLog()
let sender = AuditedOutbox(outbox: outbox, auditLog: audit)
```

Each policy instance holds an immutable owner-rule snapshot. An omitted issue defaults to `askEachTime`. Duplicate rules use `never`, then `askEachTime`, then `allowOnDevicePeers`, in that order. A never rule cannot be overridden by consent. `allowOnDevicePeers` requires a card declaring `.onDevice` or `.none` and a matching paired-peer store entry. `.none` means the peer declares no model. A missing store or absent peer falls back to consent; a store error denies automatic sharing.

`onlyOnDeviceAgents` denies all non-hello traffic to PCC, third-party cloud, or unknown recipients. Without that setting, those recipients require consent for each non-hello message. Hello is the bootstrap exception, containing only the agent card. A card's locality is always self-declared. The caller must bind cards to peers using the authenticated Inbox flow; policy is not an identity verifier.

## Required context for lane F

An answer contains only a query ID, so register the received query envelope after Inbox accepts it:

```swift
try await policy.registerReceivedQuery(queryEnvelope)
```

Before sending any PSI step, register the exact frame, destination, conversation, actual local provider descriptor, and complete semantic inputs:

```swift
try await policy.registerPSIStep(
    frame, to: friend, conversation: conversation,
    provider: psiProvider.descriptor, inputs: inputTerms
)
```

`inputTerms` describes the complete local input set using typed issue values, not a private constraint or a peer-provided claim. Even private providers carry protected issue keys through policy; a never rule still blocks them. Non-private providers disclose the whole input set and force consent on every step, including replies and empty payloads. Private providers omit raw input values from disclosure and still honor issue rules. Empty input descriptions require consent. Unknown query references, unregistered PSI steps, and changed PSI payloads are denied.

Registrations are bound to the peer and conversation. Query registrations also bind both endpoint IDs and the query ID. Identical registrations are idempotent; conflicting replacements throw. The combined registry is capped at 256 entries and refuses additional entries instead of evicting a live rule. At negotiation completion or abandonment, call:

```swift
await policy.forgetConversation(conversation, with: friend)
```

## Consent data for lane H

`ConsentSheetModel(disclosure:)` is a Sendable, Hashable value with recipient, rows, locality copy, and protocol/PSI notices. Each row preserves its exact `DisclosedItem` for richer or localized rendering. It contains no SwiftUI, model calls, or user decision state. The app's `ConsentProvider` must suspend until an explicit decision and default dismissal to declined.

| Body | Disclosure items |
|------|------------------|
| hello | Agent-card marker |
| propose, counter, accept | Every term, sorted by issue key |
| reject | No owner issue values |
| query | Exact issue and candidates |
| answered answer | Registered query issue and exact acceptable value |
| declined/pending answer | No owner issue values |
| non-private psi | Every input issue and value, categorized as PSI |
| private psi | Input issue keys and PSI markers, without input values |

Time is categorized as availability, activity as interest, and other issues as terms. Empty lists, false flags, and zero counts remain explicit values. Times show UTC and the exclusive end. USD amounts show cents as decimals; other currency codes retain exact minor units so the presentation does not guess a scale.

Core Disclosure cannot express exact card fields, control-message status, provider identity, or all envelope metadata. Markers and the protocol notice label those limitations; they do not invent IssueValues. See [G's integration requests](../../docs/requests/G.md) for the additive metadata request. In particular, a PSI marker with no values cannot identify the provider's privacy status, so its notice makes no privacy claim.

## Audit semantics

`AuditedOutbox.send` delegates to Core Outbox and appends only after send success. A record means successful handoff to the transport, not confirmed peer receipt. Denials, consent declines, and throwing transport or encoding failures do not create success records. A throwing transport could still have partially sent data; absence of a success record cannot prove nothing left the link.

Audit storage retains message ID, recipient, completion timestamp, body kind, issue keys when present on wire, and coarse value kinds. It never retains raw amounts, currency, flags, counts, keywords, availability, card contents, or PSI bytes. Answers and PSI retain only their available on-wire summary, without guessing missing issues. `InMemoryAuditLog` retains the latest 1,000 records by append order by default, supports clearing, and is not persistent across launches.

All feature sends must use the wrapper for auditing. Consumers requiring concrete Core Outbox need the Orchestrator's completion-hook change described in the requests file. Pending consent must be declined before replacing policy snapshots or removing peer trust; current Core Outbox does not re-evaluate policy after consent, and cancellation alone is insufficient.

## Verification

Run `Tools/test-all.sh StarlingPolicy` from the repository root. Tests cover the full message/rule matrix, locality, context isolation, private and non-private PSI, consent suspension, Loopback with Inbox, and audit redaction/failure paths. No model or iPhone is required. Device checks are in [phase-1-G.md](../../docs/checklists/phase-1-G.md).
