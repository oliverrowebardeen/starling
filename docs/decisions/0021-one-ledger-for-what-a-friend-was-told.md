# ADR 0021: One ledger for what a friend was told, enforced by Outbox

- Status: Accepted
- Date: 2026-10-01
- Owner: Orchestrator
- Amends: ADR 0019 (decision 6), ADR 0011 (decision 5)

## Context

ADR 0019 bounds how much a run of yes/no answers can teach: at most `ProtocolLimits.maxCandidatesAnsweredPerIssue` (16) candidates per issue per conversation. ADR 0011 amendment 15 asks every skill to ignore late messages for conversations that have ended. Lanes B, C, and D each built this into their own skill state, and the final reviews of PRs #53, #55, and #56 found each version leaking at a different edge:

- A ledger kept for 24 hours only, so a peer reused an ended conversation's ID after a day.
- A bounded tombstone cache, so a peer churned 257 conversations to evict the record of a withdrawal.
- A budget kept on a run, so replacing the run reset it.
- A ledger that read as empty when storage failed.
- Budgets that a relaunch refilled.

The review of PR #51 found a related gap in the audit: an `OutboxObserver` heard about a send only after the transport took it, so a crash in between left no record, and What left your phone could claim a topic stayed on the phone.

## Decision

1. **`ConversationLedger`** (StarlingCore) is one persistent, fail-closed record per phone:
   - **Retired conversations, kept for good.** `retire(_:)` on every ending, withdrawal included. Nothing is sent in a retired conversation again, and a skill opens nothing for one.
   - **Distinct candidates answered**, per friend, conversation, and issue. `reserve(_:issue:to:in:)` adds the candidates an answer covers, and refuses, reserving nothing, past the limit or in a retired conversation. Asking again about a candidate already reserved costs nothing.
   - Every change is durable before it returns, and a ledger that cannot read or write throws.
2. **Outbox enforces it** when the app passes one (`Outbox(ledger:)`):
   - It throws `conversationRetired` for any send in a retired conversation.
   - For an `.answer` with `OutboundContext.answering`, it reserves the query's candidates first, and throws `answerLimitReached` when the ledger refuses.
   - A ledger error stops the send.
   - This runs after the policy and consent clear the send and before it is numbered, so a refusal leaves no gap (ADR 0020, review of PR #53).
   - Because every answer passes Outbox, no skill can forget the limit. Skills still retire conversations, and they check `isRetired` before opening an interaction for an incoming request.
3. **Skills drop their own ledgers and tombstones** for this. A skill-specific budget that is not about candidates, such as Down for…'s private set intersection runs per friend, stays with the skill. It is persisted with the request, so a relaunch never refills it.
4. **The audit hears before a send leaves.** `OutboxObserver.outbox(willSend:context:decision:disclosed:)` runs after the checks and before the transport takes the envelope, and throwing stops the send.
   - Lane E's egress recorder durably notes the send there as pending, with its items, and settles it in `didSend`.
   - A crash in between leaves a pending note, which marks the interaction's log unknown on the next launch, never a claim that something stayed on the phone.
5. **Queued encrypted sends honor cancellation.** `SecureTransport` sends one at a time. A send cancelled while it waits behind another never seals or leaves. This fixes a withdrawn offer queued behind a stalled send (review of PR #51).
6. **The app persists the ledger** (lane A), next to the `SentSequenceStore`. `StarlingFakes.InMemoryConversationLedger` is the double.

## Consequences

- One place to test, which lane F does: limits, retirement, failure, and restart.
- Lanes B, C, D, and E replace their own budget and tombstone code with the ledger and the hooks. Lane A persists the ledger and installs it.
- The record of retired conversations grows by one ID per ended conversation and is never pruned. That is a few bytes per conversation, kept for the life of the install.

## Sources

- Reviews of PRs #51, #53, #55, and #56 (Codex), 2026-10-01
- ADRs 0011, 0019, 0020; `Packages/StarlingCore/Sources/StarlingCore/ConversationLedger.swift` and `Outbox.swift`
