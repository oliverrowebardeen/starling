# ADR 0120: Down? negotiation protocol

- Status: Proposed
- Date: 2026-09-30
- Owner: F. Negotiation

## Context

ARCHITECTURE.md section 7 sets the Down? contract: mutual interest through PSI first, details only after overlap, `DownEvent.matched` only after both sides accept, levels exchanged only then, and silence on every failure. It leaves the details to lane F. The constraints that shape them:

- Delivery is best effort (ARCHITECTURE rule 2.5). Any step can be lost, and the app may be closed.
- Set sizes are visible in DH-based PSI, and a dishonest peer can submit every slot in a small domain to learn the whole set (brief 3.9).
- `InsecurePSIStub` reveals the initiator's set to the responder, so while it is in use the policy layer asks for consent on PSI frames (section 7, step 4). A consent sheet shows the recipient, so it is itself a notification.
- The frozen v1 messages had no field for the level (`down`/`maybe`) and have no way to tag a conversation as Down. Core v1.1 added `IssueKey.downLevel` for the first; the second is deferred to Phase 2.

## Decision

### Roles

1. Any phone with an active intent starts a PSI run with each reachable paired friend: when the intent is set, and when a friend's link comes up. A friend whose `hello` card lacks `Capability.down` is skipped.
2. If both start at once, the run started by the lower `PeerID` goes ahead and the other side abandons its own. The tie-break comes before the run cap in item 4, so it works on the last allowed run too. Retries resolve the case where the winning request was lost.
3. A phone with **no** intent does not answer. It never shows a consent sheet, never runs the model, and its owner learns nothing. To the starter, this looks the same as an unreachable phone.
4. Per intent, at most `maxRunsPerPeer` (default 3) runs with one friend in either role. A run that ended with no overlap, a rejection, a match, or a policy refusal is not retried with that friend during the same intent. Only a timeout allows another run, for example after a link heals.

### Step 1: mutual interest (PSI)

5. Tokens are UTF-8 `starling/down/v1/slot/<startMinute>`, one per UTC-aligned 30-minute slot that breaks none of the owner's time limits, lies between now and the intent's expiry, and is among the first 24 such slots. "Now" is when each run starts, not when the intent was set, so a run after a delay offers only slots still ahead. A run with no slots left does not start.
6. Every set is padded with random `starling/down/v1/pad/<hex>` tokens to exactly 24 elements, and `maxPeerSetSize` is 24. A peer therefore cannot tell how much free time the owner has from the set size, and one run probes at most 12 hours of slots.
7. The level is not an input to the token set, so `down` and `maybe` produce identical tokens.
8. Every PSI step passes `OutboundContext.psi` to the Outbox: the provider's descriptor and the free slots the set was built from (`[.time: .slots(...)]`; padding is not an input). The policy uses it to judge what the step discloses and refuses a PSI step without it (Core v1.1).
9. The initiator must learn the intersection (the stub gives it to both roles). An empty result ends the conversation on both phones with no further message.

### Step 2: details, only after overlap

10. The initiator sends `query(activity, keywords: its liked activities)` if it has any, and `query(budget, amount: its cap)` if it has one.
11. The responder answers the activity query with the acceptable subset of the candidates: one `AgentModel.match` call if the owner has liked activities, none otherwise (ADR 0121). The budget answer is the lower of the two caps, or `declined` if the currencies differ. Answers are cached, so a retried query gets the same answer without a second model call. Each of the two issues is answered once per conversation; any other query gets no answer. The details phase, from the end of PSI to the offer, has one fixed deadline (twice a step's budget) that answering does not reset.
12. An empty activity answer means no shared activity, and the conversation ends without an offer.

### Step 3: agree

13. The initiator proposes round 0: the first contiguous block of shared slots that have not started by the time the plan is chosen (PSI and consent can take a while), capped at 2 hours; the first liked activity the peer accepted; the answered budget.
14. The receiver of any offer checks it in code, including against the clock: an offer whose start minute has passed is rejected as expired. No offer or accept of such a plan is sent (retries included) or honored. An accept still waiting on consent when its plan's start minute ends is cancelled. The offerer checks the time again after its confirmation is sent and does not notify if the plan has started meanwhile. A compliant offer is accepted, or countered with an alternative when a soft preference is unmet (ADR 0121). A non-compliant offer gets a counter repaired in code: budget down to the cap, avoided activities dropped, the time shortened from its end. If nothing can be repaired, or `maxRounds` (default 4) is reached, it gets a `reject`.

### Step 4: match before notify

15. The phone that did not make the final offer (the **acceptor**) sends `accept` with the offered plan plus its own level under `IssueKey.downLevel` (`down_level`, with `keywords: ["down"]` or `["maybe"]`).
16. The **offerer** checks that the accept names one of its offer envelopes, carries exactly its plan, and has a valid level. It then sends its own `accept` of the same plan with its level (the **confirmation**), and after that send succeeds it emits `DownEvent.matched`.
17. The acceptor emits `matched` when the confirmation arrives. `bothDown` is true only when both levels are `down`.
18. Each level crosses the wire only after the other side has committed to the identical plan (by offering it or accepting it), so a `maybe` is revealed only when interest is mutual.

### Retries and silence

19. Every step that expects a reply is resent every `retryInterval` (default 5 s) up to `maxAttempts` (default 6) times, and every wait is bounded the same way. A timeout ends the conversation without an event. Deadlines run outside the friend's work queue, so a stalled model call or an unanswered consent sheet cannot hold one back: when a step's deadline passes, the conversation ends and the work it was waiting on is cancelled. A send waiting on consent is therefore bounded by the current step's deadline, which is also how long the peer keeps waiting.
20. A retry arrives in a new envelope, so duplicates are recognized by content (PSI step and payload, query, offer round and terms, accept terms) and answered from a reply cache. A retried offer's new envelope is recorded as the same offer before the cached accept is replayed against it, so the confirmation that answers the replay is honored. After a conversation ends, its cache is replayed only if it ended **matched** under the intent that is still current, which is the lost-confirmation case. After any other ending (withdrawn, expired, refused, rejected, timed out, failed) a late retry gets nothing, so a withdrawal cannot be undone by a replayed accept and a declined consent sheet is not raised again.
21. Rejections, timeouts, withdrawn or expired intents, policy refusals, and malformed or oversized input all end without an event on either phone. Clearing an intent sends nothing to friends.
22. Ending a conversation, or the whole intent, cancels its sends still inside the Outbox (for example waiting on the owner's consent) and its model calls, and stops the rest of any batch. The Outbox checks cancellation after consent and before the transport, so nothing from a withdrawn intent leaves, whenever the owner answers the sheet.

## Consequences

- **No false match:** a phone notifies only while holding the peer's accept of the identical plan. The tests check this on the wire for every match.
- **A missed match is possible** when the confirmation is lost and every retry of the acceptor's accept is also lost. The offerer then notifies and the acceptor does not. No finite exchange over a lossy link can rule this out (the two generals problem); the retries make it unlikely on a live link. The offerer's owner sees a real plan the friend accepted.
- **What one-sided interest reveals:** the starter learns "no reply," which looks the same as "unreachable." The receiver, if it has no intent, learns (with the stub) the starter's free slots and nothing reaches its owner. With real PSI it learns nothing beyond the fact that a run was attempted. A friend with an intent but no shared time learns the empty result.
- **Remaining leak:** the existence of a PSI run shows that the starter has Down turned on. Hiding this would take cover traffic (periodic runs with dummy sets), which with the stub means constant consent prompts. Recorded for the threat model; revisit when Nightjar's PSI lands.
- **A dishonest friend** can still learn our free slots within the next 12 hours by submitting every slot. The set cap and the three-runs-per-intent cap bound it; they do not remove it.
- **PSI initiator requirement:** a provider whose initiator learns nothing would need the responder to drive step 2. Nightjar's API must be checked against this when it lands.
- Routing every conversation that opens with a PSI step to Down is a Phase 1 workaround; a per-conversation feature tag is deferred to Phase 2 (`docs/requests/F.md`, request 4).

## Sources

- Brief sections 2.6 (Down, match-before-notify), 2.7 (mutual reveal, private query), and 3.9 (PSI set-size risk), `docs/BRIEF.md`.
- ARCHITECTURE.md sections 2 (rules 5 to 7) and 7.
- OpenMined PSI (the brief's reference implementation): "The client sends its encrypted elements to the server," so the server sees how many there are, and it can reveal the intersection or only its size. https://github.com/OpenMined/PSI
- The impossibility of guaranteed agreement over a lossy channel: E. A. Akkoyunlu, K. Ekanadham, R. V. Huber, "Some constraints and tradeoffs in the design of network communications," SOSP 1975, https://doi.org/10.1145/800213.806523 ; named the two generals problem by J. Gray, "Notes on Data Base Operating Systems," 1978.
