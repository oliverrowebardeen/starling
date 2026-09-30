# StarlingPolicy

Deterministic policy, consent presentation values, and a local audit observer for Core v1.1. The production target depends only on StarlingCore. The transport dependency is test-only for the authorized Loopback acceptance tests.

## Composition

```swift
let policy = DeterministicPolicyEngine(
    ownerRules: reviewedRules,
    onlyOnDeviceAgents: true,
    pairedPeers: pairedPeerStore
)
let audit = try InMemoryAuditLog()
let outbox = Outbox(
    transport: secureChannel, policy: policy,
    consent: consentProvider, observer: audit
)
```

Each policy value holds an immutable owner-rule snapshot. An omitted issue defaults to `askEachTime`. Duplicate rules use `never`, then `askEachTime`, then `allowOnDevicePeers`, in that order. A never rule cannot be overridden by consent. `allowOnDevicePeers` requires a card declaring `.onDevice` or `.none` and a matching paired-peer store entry. `.none` means the peer declares no model. A missing store or absent peer falls back to consent; a store error denies automatic sharing.

`onlyOnDeviceAgents` denies all non-hello traffic to PCC, third-party cloud, or unknown recipients. Without that setting, those recipients require consent for each non-hello message. Hello is the bootstrap exception, containing only the agent card. A card's locality is always self-declared. The caller must bind cards to peers using the authenticated Inbox flow; policy is not an identity verifier.

## Sender context for lane F

Answers name their issue in the envelope. Every PSI send supplies trusted local provenance directly to Core Outbox:

```swift
try await outbox.send(
    .psi(frame), to: friend, conversation: conversation,
    recipientCard: friendCard,
    context: OutboundContext(psi: .init(
        provider: psiProvider.descriptor,
        inputs: inputTerms.values
    ))
)
```

The context describes the actual local provider and complete semantic input set using typed issue values, not a private constraint or a peer-provided claim. Context remains local and is never encoded on the wire. Every PSI step without `context.psi` is denied. Invalid typed inputs are also denied, since Core's context dictionary has no validating initializer. No registration, lookup cache, or cleanup is needed.

Even private providers carry protected issue keys through policy; a never rule still blocks them. Non-private providers disclose the whole input set and force consent on every step, including replies and empty payloads. Private providers omit raw input values from disclosure and still honor issue rules. Empty input descriptions require consent.

## Consent data for lane H

`ConsentSheetModel(disclosure:)` is a Sendable, Hashable value with recipient, rows, locality copy, and protocol/PSI notices. Each row preserves its exact `DisclosedItem` for richer or localized rendering. It contains no SwiftUI, model calls, or user decision state. The app's `ConsentProvider` suspends until an explicit decision and treats dismissal as declined. Core Outbox handles cancellation and re-evaluates policy after approval.

| Body | Disclosure items |
|------|------------------|
| hello | Agent-card marker |
| propose, counter, accept | Every term, sorted by issue key |
| reject | No owner issue values |
| query | Exact issue and candidates |
| answered answer | `Answer.issue` and exact acceptable value |
| declined/pending answer | No owner issue values |
| non-private psi | Every context input issue and value, categorized as PSI |
| private psi | Context input issue keys and PSI markers, without input values |

Time is categorized as availability, activity and `downLevel` as interest, and other issues as terms. A `downLevel` acceptance term containing the keyword `down` or `maybe` appears as Your interest with `You said "down".` or `You said "maybe".`. It follows the same disclosure rules as other issues, including never and the default consent requirement. F controls when mutual agreement permits sending that term.

Empty lists, false flags, and zero counts remain explicit values. Times show UTC and the exclusive end. USD amounts show cents as decimals; other currency codes retain exact minor units so the presentation does not guess a scale.

Core Disclosure still cannot express exact card fields, control-message status, provider identity, or all envelope metadata. Markers and the protocol notice label those limitations; they do not invent IssueValues. See [G's integration requests](../../docs/requests/G.md), item 4. A PSI marker with no values cannot identify the provider's privacy status, so its notice makes no privacy claim.

## Audit semantics

`AuditLog` conforms to Core's `OutboxObserver`. Install `InMemoryAuditLog` as `Outbox(observer:)`; consumers keep using concrete Core Outbox. The observer appends only after send success. A record means successful handoff to the transport, not confirmed peer receipt. Denials, consent declines, cancellations before transport, and throwing transport or encoding failures do not create success records. A throwing transport could still have partially sent data; absence of a success record cannot prove nothing left the link.

Audit storage retains message ID, recipient, completion timestamp, body kind, issue keys, and coarse value kinds. Answers use their on-wire issue, and PSI uses local context for issue summaries. Private PSI records issue markers without input value kinds. The log never retains raw amounts, currency, flags, counts, keywords, availability, Down levels, card contents, PSI bytes, original context, or consent Disclosure. `InMemoryAuditLog` retains the latest 1,000 records by append order by default, supports clearing, and is not persistent across launches.

## Verification

Run `Tools/test-all.sh StarlingPolicy` from the repository root. Tests cover the full message/rule matrix, locality, per-send PSI context, private and non-private PSI, Down level consent, consent suspension and cancellation, policy changes during consent, Loopback with Inbox, and audit redaction/failure paths. No model or iPhone is required. Device checks are in [phase-1-G.md](../../docs/checklists/phase-1-G.md). The Core v1.1 integration decision is [ADR 0131](../../docs/decisions/0131-core-v11-policy-integration.md).
