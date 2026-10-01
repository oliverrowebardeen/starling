# ADR 0210: Down for... as a group skill

- Status: Proposed
- Date: 2026-10-01
- Owner: P15-B. Down for... skill and the model

## Context

Phase 1's `DownNegotiator` (ADRs 0120, 0121) matched two phones at a time and fired `DownEvent.matched` on each. Phase 1.5 makes Down for... the first skill on the v2 contract (ADRs 0010 to 0012) and changes what the owner sees:

- Each owner's request is an initiator `Interaction`. Home shows a proposal card under Needs you, the owner taps "I'm in" for a revision, and "It's a plan" comes only after everyone confirmed (mockup "Home": "You, Maya and Jake are all down for boba").
- A plan is a group, with the agreed roster in `IssueValue.peers` so every phone builds the same `Plan.attendees` (ADR 0012, amendment 8).
- Every envelope carries the skill's `SkillRef`; a peer's message never starts anything (ARCHITECTURE rule 8).

Phase 1's semantics stay: PSI over free half-hours first, details only after overlap, hard limits in code, deadlines and idempotent retries, silence on failure, and nothing shown to anyone on one-sided interest.

Two facts shape the design:

- **Delivery is best effort, and phones are not always reachable** (ARCHITECTURE rule 5). There is no coordinator to ask who is down, and asking would reveal it.
- **Several friends can be down at once, each with their own request.** Their agents must end up in one group, not several overlapping ones, without anyone learning who passed.

## Decision

### Who runs a group

1. **The starter is the hub.** A request's conversation is its starter's. The starter runs a PSI with each friend in the audience, asks for details only where time overlaps, builds one plan from everyone's private answers (private aggregation, brief 2.7), and proposes it to the friends in it.
2. **A friend answers only from an open request of its own that includes the starter** (Phase 1, ADR 0120 item 3). A phone without one never answers, shows no sheet, and runs no model, so to the starter it looks unreachable.
3. **The lower `PeerID` carries a pair.** When two open requests reach each other, the higher phone answers the lower one's run and drops its own run with it. A phone that gets a run from a higher starter makes sure its own run to that starter is going instead. This extends Phase 1's tie-break (ADR 0120 item 2) to groups.
4. **A request joins at most one group, preferring the lowest starter.** A friend commits to a starter when it answers that starter's first query (which proves overlap). Committing stops the request's own group and leaves a higher starter's, telling each starter left behind "no plan". A request whose owner already sees a card stays with that group.
5. **A starter proposes only after its friends have answered, or timed out,** and not while it is itself answering a lower starter's run, and not within two retry intervals of taking the request on. The last two rules give a lower starter's retries time to arrive first, which the stress runs showed is otherwise a race.

### The plan

6. **The plan that includes the most friends wins.** For each of the starter's activities and each shared half-hour, the planner counts the friends who share both; ties go to the starter's earlier preference, then the earlier time. The time grows while every chosen friend shares the next half-hour, up to two hours. The budget is the lowest cap anyone named.
7. **A group of three or more carries its roster** under `people`, starter first. **A pair does not**: its roster is the two ends of the conversation. With the default People topic (Ask me), sending it would raise a consent sheet on both phones that says only "you and Maya".
8. **Code checks every plan before it leaves and before it shows** (ARCHITECTURE rule 6): the shape above, the owner's hard limits, the request's window, and a start that is still ahead. A member shown a plan it cannot accept tells the starter "no plan" and leaves the group; no card appears.

### Cards and confirmation

9. **The proposal shows on each member's own request** as `proposalReady` with a local revision. The wire carries terms; each phone numbers its own revisions.
10. **Nobody is in a plan until everyone in it said "I'm in"** to the same terms. A member's acceptance names the terms; the starter confirms to everyone only when all members and its own owner accepted the current terms, and reports `everyoneConfirmed` once the confirmations are handed to the Outbox. A member reports it when the confirmation arrives. Both build `Plan` and `Attendees` from the terms, with the starter's conversation as the plan's origin.
11. **A stale "I'm in" never accepts newer terms.** The service refuses an answer for an old revision, `Interaction` refuses it too, and the starter ignores an acceptance whose terms are not the current ones.
12. **Passing is silent to others.** A member who passes, or does not answer within the owner window (15 minutes by default), is left out; the starter re-plans for the rest as a new revision, which they accept again because the roster is part of what they agree to. If nobody is left, the request ends as nobody up. No event on any other phone says who passed.
13. **A lost confirmation is replayed** (ADR 0120's two generals case): a member keeps resending its acceptance with backoff, and the starter answers a duplicate from its reply cache after the plan formed.

### Lifecycle and consent

14. **The service follows ADR 0011 amendments 13 and 14.** The coordinator applies `started`; the service never emits it. `withdraw` ends the request, cancels every send still in flight for it (including one waiting on a sheet), and sends nothing more. A policy denial ends the request as `blockedByPrivacy`, but only for a send made for the current step; a denial for a superseded step is dropped. A declined sheet adds no event; the coordinator applies the pass.
15. **Consent shows on the lifecycle through a relay.** The Outbox owns the sheet, so a `DownForConsentRelay` wraps the app's `ConsentProvider` and reports `consentNeeded` and `consentGiven` with rising IDs for this skill's disclosures. A disclosure the owner already approved in the request does not suspend it again.
16. **Unsupported friends are left out by card.** A friend whose card does not support `down_for@1` gets no traffic. If none is left, the request ends as unsupported. `DownForService.unsupported(among:cards:)` gives the app the per-friend reason for "Maya's Starling doesn't do this yet".
17. **`restore(_:)` resumes an open request** whose rules are in the `DownForRequestStore`, with fresh PSI runs in the same conversation. A card, a confirmation, or a sheet in flight cannot be rebuilt after a restart, so those requests end as failed. A planned request keeps its plan-end timer.

## Consequences

- One request, one card: a member sees the starter's plan on its own "Down for boba" row, not on a second interaction. The cost is that a member's sends travel in the starter's conversation, so attributing them to the member's interaction needs `DownForService.interaction(for:peer:)` (request to the Orchestrator and lane A in `docs/requests/P15-B.md`).
- **A starter can still be left out.** If a higher starter's group forms and is accepted before the lower starter's retries arrive, its members stay with it and the lower starter's request ends with nobody up. Rules 4 and 5 make this rare: before them, 5 of 40 runs of the package's tests failed this way on the development machine; after them, 30 of 30 passed with the load average between 12 and 38. Rare is not never.
- A friend left out by a re-plan learns it from the next card's roster. That is inherent in a group plan; no event names who passed.
- The same residual risks as ADR 0120 hold: a missed plan when every resend of a lost confirmation is also lost; a dishonest friend probing free time within the run cap; the stub PSI revealing the starter's slots to friends with open requests.
- Phase 1's counters and the `decide` model call are gone. The starter builds the plan from answers each friend computed under its own limits, so a friend who answered can always accept it; anything else is refused in code.

## Sources

- Brief sections 2.6 (match before notify), 2.7 (mutual reveal, private aggregation), and 3.9 (PSI set sizes).
- ARCHITECTURE.md section 2 (rules 5 to 8) and section 7.
- ADRs 0011 (amendments 8 to 14), 0012 (amendment 8), 0014, 0017, 0120, 0121.
- The impossibility of guaranteed agreement over a lossy channel: E. A. Akkoyunlu, K. Ekanadham, R. V. Huber, "Some constraints and tradeoffs in the design of network communications," SOSP 1975, https://doi.org/10.1145/800213.806523
- `Packages/Skills/DownFor/` and its tests.
