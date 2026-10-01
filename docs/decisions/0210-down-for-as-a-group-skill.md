# ADR 0210: Down for... as a group skill

- Status: Proposed
- Date: 2026-10-01; revised the same day for Core v2.1 (ADRs 0019, 0020, ADR 0011 amendment 15) and the adversarial review of PR #56
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
4a. **Every run counts toward the cap.** Only a run this phone started that the friend never answered goes back to `maxRunsPerPeer` when the friend's simultaneous run wins (review finding 3); runs a friend starts in fresh conversations all count, so they cannot probe free time past the cap.
5. **A starter proposes only after its friends have answered, or timed out,** and not while it is itself answering a lower starter's run, and not within two retry intervals of taking the request on. The last two rules give a lower starter's retries time to arrive first, which the stress runs showed is otherwise a race.

### The plan

6. **The plan that includes the most friends wins.** For each of the starter's activities and each shared half-hour, the planner takes the largest set of friends who share both and who may all be together (decision 22); ties go to the starter's earlier preference, then the earlier time. The time grows while every chosen friend shares the next half-hour, up to two hours.
6a. **Budget stays on the phone.** Budget defaults to Never (ADR 0019), and the policy denies any envelope that carries a Never value, which would end every request as blocked. So no budget query and no budget in a plan; budget stays a chip for a chained Pick a place to use. Activity answers are subsets of the starter's own candidates (at most 16), sent with `OutboundContext.answering`, so they pass as yes or no answers under any choice. Likewise every "I'm in" names the proposal it accepts in `OutboundContext.accepting` (ADR 0019 amendment 10).
7. **A group of three or more carries its roster** under `people`, starter first. **A pair does not**: its roster is the two ends of the conversation. With the default People topic (Ask me), sending it would raise a consent sheet on both phones that says only "you and Maya".
8. **Code checks every plan before it leaves and before it shows** (ARCHITECTURE rule 6): the shape above, the owner's hard limits, the request's window, and a start that is still ahead. A member shown a plan it cannot accept tells the starter "no plan" and leaves the group; no card appears.

### Cards and confirmation

9. **The proposal shows on each member's own request** as `proposalReady` with a local revision. The wire carries terms; each phone numbers its own revisions.
10. **Nobody is in a plan until everyone in it said "I'm in"** to the same terms. A member's acceptance names the terms; the starter confirms to everyone only when all members and its own owner accepted the current terms, and reports `everyoneConfirmed` once the confirmations are handed to the Outbox. A member reports it when the confirmation arrives. Both build `Plan` and `Attendees` from the terms, with the starter's conversation as the plan's origin.
11. **A stale "I'm in" never accepts newer terms.** The service refuses an answer for an old revision, `Interaction` refuses it too, and the starter ignores an acceptance whose terms are not the current ones.
12. **A pass looks exactly like no answer** (review finding 4). A pass, a withdrawal, an expiry, and a group that fell apart send nothing at all. A member who passes is left out when the owner window (15 minutes by default) passes, as one who never answered is; the starter then re-plans for the rest as a new revision, which they accept again because the roster is part of what they agree to. If nobody is left, the request ends as nobody up. A test compares a pass and silence on the wire and in the starter's events and timing.
12a. **Rounds only rise** (review finding 5). A member keeps the highest proposal round it has seen; a lower round, even in a fresh envelope, never replaces the card, and a second set of terms for the same round is ignored. A confirmation must name a proposal envelope that carried the accepted terms.
13. **A lost confirmation is replayed** (ADR 0120's two generals case): a member keeps resending its acceptance with backoff, and the starter answers a duplicate from its reply cache, only while its request is planned. Cached replies belong to their request and go when it ends, and nothing leaves for a request that is no longer live (review finding 2).

### Lifecycle and consent

14. **The service follows ADR 0011 amendments 13 to 15.** The coordinator applies `started`, every consent event, and `planEnded`; the service emits none of them. `withdraw` ends the request, cancels every send still in flight for it (including one waiting on a sheet), and sends nothing more. A policy denial ends the request as `blockedByPrivacy`, but only for a send made for the current step; a denial for a superseded step is dropped. A declined sheet adds no event.
15. **Every send names its interaction** in `OutboundContext.interaction`, including a member's sends in the starter's conversation, so the coordinator's consent sheet and the egress log attribute them to the member's own request.
16. **Unsupported friends are left out by card.** A friend whose card does not support `down_for@1` gets no traffic. If none is left, the request ends as unsupported. `DownForService.unsupported(among:cards:)` gives the app the per-friend reason for "Maya's Starling doesn't do this yet".
17. **`restore(_:)` resumes an open request** whose rules are in the `DownForRequestStore`, with fresh PSI runs in the same conversation (Core's `Outbox` keeps sequence numbers rising across the restart). A card or a confirmation in flight cannot be rebuilt, so those requests end as failed. A planned request is kept quietly for its replays until 30 minutes after its plan ends. Interactions that ended in the last 24 hours mark their conversations ended, so a late retry never reopens one.

### Send modes (ADR 0020)

18. **Ask quietly is the default; Invite is the other mode.** Every envelope carries its conversation's mode, a member echoes it, and an envelope in a mode the skill does not offer, or in a mode its conversation did not begin with, is ignored. A quiet ask never becomes a card.
19. **An invitation is the starter's plan, sent straight to each friend**: the first block of its own free time, up to two hours, and its first activity. No mutual reveal, since an invitation is meant to be seen.
20. **An invitee sees a card on an invitee interaction** (`incoming`, then `proposalReady`), whether or not it has a request of its own. Only a paired friend's invitation shows when the app passes its `PairedPeerStore`, and one friend can put at most three live invitations on a phone.
21. **The starter keeps whoever said I'm in**, at the owner window or once all have, and shows its own card with them; on its I'm in it confirms with the roster of those friends (for three or more), which each invitee checks equals the invitation plus that roster. Friends who did not answer are told "no plan".
22. **A roster names only friends each member asked** (review finding 1). Before naming anyone to anyone, the starter asks each member which of the other candidates its own request includes: a PSI over friend tokens, the starter as initiator, with only the friends that member could share a plan with, padded to a fixed size, at most twice per member. A group is the largest set whose members all asked each other. A member also refuses, as an ordinary no, a roster that names someone its request does not include. With a private PSI provider a member learns nothing from the check; with the insecure stub it learns the starter's candidates, which the consent sheet shows while the stub is in use.
23. **A no is an ordinary no.** Any refusal that comes from the owner's limits says `noOverlap`, never `policy` (ADR 0019 decision 5).
24. **Exclusion is undetectable** (ADR 0020 decision 9). A quiet ask from someone outside the participants of your own matching request gets what a friend who is not down gets: nothing, ever. A test compares the two.

## Consequences

- One request, one card in Ask quietly: a member sees the starter's plan on its own "Down for boba" row, not on a second interaction. A member's sends travel in the starter's conversation and name the member's interaction in `OutboundContext` (decision 15). An invitation is a separate invitee card.
- **A starter can still be left out.** If a higher starter's group forms and is accepted before the lower starter's retries arrive, its members stay with it and the lower starter's request ends with nobody up. Rules 4 and 5 make this rare: before them, 5 of 40 runs of the package's tests failed this way on the development machine; after them, 30 of 30 passed with the load average between 12 and 38. Rare is not never.
- A friend left out by a re-plan learns it from the next card's roster. That is inherent in a group plan; no event names who passed.
- A pass now waits for the window like silence does, so a group whose member passed moves on only when the window passes (15 minutes by default) rather than at once. That delay is the price of decision 12.
- The audience check costs a PSI round per member before a group plan, and with the stub it reveals the starter's interested candidates to each member it asks. Real PSI (Nightjar) removes that; until then the consent sheet says so.
- Budget is now only a chip in Down for...: its plans carry no price, so nothing is checked against it until a place is chosen, where Pick a place (lane D) uses each owner's budget locally to judge venues.
- The same residual risks as ADR 0120 hold: a missed plan when every resend of a lost confirmation is also lost; a dishonest friend probing free time within the run cap; the stub PSI revealing the starter's slots to friends with open requests.
- Phase 1's counters and the `decide` model call are gone. The starter builds the plan from answers each friend computed under its own limits, so a friend who answered can always accept it; anything else is refused in code.

## Sources

- Brief sections 2.6 (match before notify), 2.7 (mutual reveal, private aggregation), and 3.9 (PSI set sizes).
- ARCHITECTURE.md section 2 (rules 5 to 8) and section 7.
- ADRs 0011 (amendments 8 to 14), 0012 (amendment 8), 0014, 0017, 0120, 0121.
- The impossibility of guaranteed agreement over a lossy channel: E. A. Akkoyunlu, K. Ekanadham, R. V. Huber, "Some constraints and tradeoffs in the design of network communications," SOSP 1975, https://doi.org/10.1145/800213.806523
- `Packages/Skills/DownFor/` and its tests.
