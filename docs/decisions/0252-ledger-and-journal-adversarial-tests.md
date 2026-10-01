# ADR 0252: Test shared ledger enforcement and pre-send journal boundaries

- Status: Accepted for P15-F tests only
- Date: 2026-10-01
- Owner: P15-F, red team
- Updates: ADR 0251 decision 4, where the candidate limit was still service state

## Context

ADR 0021 and PR #60 (`4d6ae20`) move distinct-candidate counting and permanent
conversation retirement into a shared ConversationLedger enforced by Outbox.
They also add a throwing pre-send observer, cancellation of retired sends, and
sequence numbers per recipient. The app and skills install these contracts in
their own lanes. F must distinguish testing the contract from proving durable
storage and actual service integration.

## Decision

1. Use StarlingFakes.InMemoryConversationLedger across replacement Outboxes to
   test retained candidate budgets and retired IDs. Try more than 257 retired
   conversations and more than 24 hours. The fake is not a filesystem restart
   test. Disk reopening, corrupt files, write failure, and never-pruned storage
   stay on the real implementation matrix in issue #49.
2. Exercise seven candidate shapes, all three scope keys, concurrent attempts,
   new query IDs, skill/chain metadata changes, and both queried and returned
   candidates. A failed oversized reservation changes nothing. Refused policy
   and consent do not spend candidates; a later journal failure conservatively
   retains the reservation already made.
3. Use the real Policy engine for consent ordering and the pre-send disclosure
   test. Script policy only when isolating the ledger's independent enforcement,
   such as a return value wider than a query. Keep query-ID, sender, and current
   step binding on the real service matrix: Query still lacks those fields.
4. Use Simulation(security: .secureChannel) for recipient isolation and a
   cancelled offer behind another conversation's encrypted send. Inject link
   latency and require that the blocking send is still in flight before retiring
   the queued one. All application messages pass Outbox; the existing Inbox
   remains the sole event consumer.
5. Observe journal items and MessageID before transport, then settlement after
   success. Refuse, suspend, or fail after capture to exercise pending records.
   E's durable pending-to-unknown recovery remains a separate integration case.
6. Pin the accepted cancellation boundary. On this launch, a queued cancellation
   takes no number and a transport cancellation returns its number. After a
   restart with a backward clock, the durable sequence store can leave one gap,
   as ADR 0021 amendment 11 explicitly permits. Do not misreport it as a new leak.

## Consequences

The suite stays deterministic and device-free, with no real model calls or
machine-load stress. Passing it proves the exercised Core, Policy, and secure
transport boundaries. It does not prove that an unmerged app installed them or
that every skill retires on every ending. PR #50 remains draft for those passes.

## Sources

- [Shared ledger contract](0021-one-ledger-for-what-a-friend-was-told.md).
- [Ledger and candidate decomposition](../../Packages/StarlingCore/Sources/StarlingCore/ConversationLedger.swift).
- [Outbox enforcement and observer ordering](../../Packages/StarlingCore/Sources/StarlingCore/Outbox.swift).
- [In-memory doubles](../../Packages/StarlingCore/Sources/StarlingFakes/PolicyFakes.swift).
- [Encrypted queue cancellation](../../Packages/StarlingIdentity/Sources/StarlingIdentity/SecureTransport.swift).
- [Real implementation matrix](https://github.com/oliverrowebardeen/starling-ios/issues/49).
