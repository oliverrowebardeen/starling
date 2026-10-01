# ADR 0210: Down for..., one friend at a time

- Status: Proposed
- Date: 2026-10-01; revised the same day for Core v2.1 (ADRs 0019, 0020, ADR 0011 amendment 15), the review rounds of PR #56, and ADR 0011 amendments 16 and 17
- Owner: P15-B. Down for... skill and the model

## Context

Phase 1's `DownNegotiator` (ADRs 0120, 0121) matched two phones at a time and fired `DownEvent.matched` on each. Phase 1.5 makes Down for... the first skill on the v2 contract (ADRs 0010 to 0012): each request is an `Interaction`, a match shows as a card under Needs you, the owner taps "I'm in" for a revision, and "It's a plan" comes only after everyone in it confirmed. Every envelope carries the skill's `SkillRef`, and a peer's message never starts anything (ARCHITECTURE rule 8).

Phase 1's semantics stay: PSI over free half-hours first, details only after overlap, hard limits in code, deadlines and idempotent retries, silence on failure, and nothing shown to anyone on one-sided interest. Delivery is best effort and phones are not always reachable (ARCHITECTURE rule 5).

An earlier revision of this ADR made a quiet ask a private group reveal: the starter grouped every friend who was down into one plan with a roster. Four review rounds of PR #56 found it leaking interest or exclusion across friends' audiences, through rosters, an audience check, coupled schedules, and a capped candidate list, round after round. ADR 0011 amendment 17 therefore makes quiet asks one-to-one for Phase 1.5, and a group plan an explicit invitation. The superseded decisions are listed at the end.

## Decision

### One friend per quiet ask (ADR 0011 amendment 17)

1. **A quiet ask is one friend's own interaction.** For an Ask quietly request, the app's coordinator starts one initiator interaction per resolved friend, each with its own conversation, the same `SkillIntent`, and that one friend as participant. Home groups them under the request for display only. The service refuses a quiet ask that names more than one friend (`DownForError.oneFriendPerQuietAsk`); an invitation may name several.
2. **A friend answers only from an open request of its own for the starter** (Phase 1, ADR 0120 item 3). A phone without one never answers, shows no sheet, and runs no model, so to the starter it looks unreachable.
3. **The lower `PeerID` carries a pair.** When two open requests reach each other, the higher phone answers the lower one's run and drops its own run with that friend. A phone that gets a run from a higher starter makes sure its own run to that starter is going instead (ADR 0120 item 2). Only a run this phone started that the friend never answered goes back to `maxRunsPerPeer` when the friend's simultaneous run wins; runs a friend starts in fresh conversations all count, so they cannot probe free time past the cap.
4. **Nothing in one exchange depends on another friend.** Each friend has its own queue, schedule, and plan. There is no gathering window, no audience check, no roster, and no list of other friends in a quiet ask; the only thing two exchanges share is the owner's own rules. So what a friend receives, and when, is a function of that friend's answers and the owner's taps alone. A transcript test toggles another friend's interest and compares everything that reaches the first: kinds, order, plan, count, and timing.

### The plan

5. **A pair plan**: the starter's first liked activity the friend accepts, at the first shared half-hour still ahead, grown while the next half-hour is shared too, up to two hours. A pair carries no roster: its roster is the two ends of the conversation, so the People topic raises no sheet for "you and Maya".
6. **Budget stays on the phone.** Budget defaults to Never (ADR 0019), so no budget query and no budget in a plan; budget stays a chip for a chained Pick a place. Activity answers are subsets of the starter's own candidates (at most 16), sent with `OutboundContext.answering`, so they pass as yes or no answers. Every "I'm in" names the proposal it accepts in `OutboundContext.accepting` (ADR 0019 amendment 10).
7. **Code checks every plan before it leaves and before it shows** (ARCHITECTURE rule 6): the shape above, the owner's hard limits, the request's window, and a start that is still ahead. A quiet plan that names anyone under `people` is refused. A member shown a plan it cannot accept tells the starter "no plan"; no card appears.

### Cards and confirmation

8. **Each match is its own card**, on the starter's interaction for that friend and on the friend's own request, as `proposalReady` with a local revision, its exact time, and its own I'm in.
9. **Nobody is in a plan until both said "I'm in"** to the same terms (ADR 0019). Nothing confirms automatically. The starter confirms once the friend and its own owner accepted the current terms, and reports `everyoneConfirmed` once the confirmation is handed to the Outbox; the friend reports it when the confirmation arrives. Both build `Plan` and `Attendees` from the terms, with the starter's conversation as the plan's origin.
10. **A stale "I'm in" never accepts newer terms.** The service refuses an answer for an old revision, `Interaction` refuses it too, and the starter ignores an acceptance whose terms are not the current ones.
11. **Rounds only rise.** A member keeps the highest proposal round it has seen; a lower round, even in a fresh envelope, never replaces the card, and a second set of terms for the same round is ignored. A confirmation must name a proposal envelope that carried the accepted terms.
12. **A member's pass looks exactly like no answer.** While a card waits on its owner the member sends nothing, whatever the starter sends: no cached reply to a resent query or PSI step, no refusal. A member run that ended after its card showed answers nothing more in that conversation. A pass, a withdrawal, an expiry, and a plan that fell apart send nothing at all. Transcript tests compare a pass and an unanswered card under probes, and on the wire and in the starter's events and timing.
13. **A starter's proposal goes out on a schedule fixed when it is sent, and a starter's pass ends only when that schedule does** (ADR 0011 amendment 16). The proposal is sent at once, then resent with backoff (from `retryInterval`, doubling, up to `maxBackoff`) for as long as the owner window (15 minutes by default) allows, whatever the starter's owner does meanwhile; only the friend's own I'm in stops it early. When the owner passes, the coordinator hides the card at once and calls the service, which keeps the request running exactly as if the owner had not answered, confirms nothing, and at the card's window, the moment silence would end it as expired, retires the conversation and reports `ownerPassed`. Friends who have not said I'm in when the window ends are told nothing. A transcript test compares a starter's pass with its silence as the friend sees them, and another checks the pass is reported, and the conversation retired, only after the window.
14. **A lost confirmation is replayed** (ADR 0120's two generals case): a member keeps resending its acceptance with backoff, and the starter answers a duplicate from its reply cache, only while its request is planned. Cached replies belong to their request and go when it ends.

### Lifecycle and consent

15. **The service follows ADR 0011 amendments 13 to 16.** The coordinator applies `started`, every consent event, and `planEnded`; the service emits none of them. `withdraw` ends the request, cancels every send still in flight for it (including one waiting on a sheet), and sends nothing more. A policy denial ends the request as `blockedByPrivacy`, but only for a send made for the current step. A declined sheet adds no event. A pass goes through the service (decision 13); a member's and an invitation's pass end at once.
16. **Every send names its interaction** in `OutboundContext.interaction`, including a member's sends in the starter's conversation, so the consent sheet and the egress log attribute them to the member's own request.
17. **Unsupported friends are left out by card.** A friend whose card does not support `down_for@1` gets no traffic, and its interaction ends as unsupported. `DownForService.unsupported(among:cards:)` gives the app the reason for "Maya's Starling doesn't do this yet".
18. **`restore(_:)` resumes an open request** whose rules, and PSI runs already spent per friend, are in the `DownForRequestStore`, with a fresh PSI run in the same conversation. A card or a confirmation in flight cannot be rebuilt, so those requests end as failed. A planned request is kept quietly for its replays until 30 minutes after its plan ends. Interactions that ended in the last 24 hours mark their conversations ended, so a late retry never reopens one.

### Send modes and groups (ADR 0020, ADR 0011 amendment 17)

19. **Ask quietly is the default; Invite is the other mode.** Every envelope carries its conversation's mode, a member echoes it, and an envelope in a mode the skill does not offer, or in a mode its conversation did not begin with, is ignored. A quiet ask never becomes a card, and only a quiet request answers a quiet ask.
20. **A group plan is an invitation.** After one or more pair plans, the starter can invite the friends it matched with in Invite mode. An invitation is the starter's plan, sent straight to each friend: the first block of its own free time, up to two hours, its first activity, and for two or more friends the roster of everyone invited under `people`, starter first, which the People topic's consent sheet shows. No mutual reveal, since an invitation is meant to be seen.
21. **An invitee sees a card on an invitee interaction** (`incoming`, then `proposalReady`) listing everyone invited, whether or not it has a request of its own. Only a paired friend's invitation shows when the app passes its `PairedPeerStore`, and one friend can put at most three live invitations on a phone.
22. **The starter keeps whoever said I'm in**, at the owner window or once all have, and shows its own card with them; on its I'm in it confirms with the roster of those friends (for three or more), which each invitee checks names the starter first and itself, names nobody who was not invited, and otherwise equals the invitation. Friends who did not answer are told "no plan".
23. **A no is an ordinary no.** Any refusal that comes from the owner's limits says `noOverlap`, never `policy` (ADR 0019 decision 5).
24. **Exclusion is undetectable** (ADR 0020 decision 9). A quiet ask from someone your own request does not include gets what a friend who is not down gets: nothing, ever.

### The conversation ledger (ADR 0021)

25. **Retired conversations come from the phone's `ConversationLedger`,** the same one the Outbox enforces. Before answering or opening anything, an invitation included, the service checks `isRetired` on the friend's queue, and a ledger that cannot say counts as retired.
26. **An ending is reported only after its retirement is durable.** Ending a request stops its runs at once, then awaits `Outbox.retire` on its own conversation and, if a card had shown, the starter's. Only then is the ending reported; if retiring fails, it is reported as failed and its conversations stay refused for the session.
27. **A starter's run begun again is answered.** A restarted starter resumes in the same conversation with a new PSI session; a member run that has not shown a card answers it within the run cap.

### Superseded

The earlier quiet group reveal is gone: one plan for every friend who was down, rosters naming them to each other, the lowest starter's group winning, an audience check over friend tokens, gathering and checking windows, each friend's own plan from its mutual audience, and the starter's card listing several friends. ADR 0011 amendment 17 says a private group reveal returns only with a design that passes a dedicated review.

## Consequences

- A starter who asks three friends quietly has three interactions and may get three cards, each with its own time. Home groups them; the owner answers each on its own.
- A group needs a second step, the invitation, which shows everyone invited to each other. That is the price of never revealing one friend's interest to another.
- A pass by a starter keeps its interaction alive, and its proposal going, until the window ends (15 minutes by default). The owner sees nothing more: the coordinator hid the card.
- Without the gathering window, a card shows as soon as the friend's answers are in, typically within seconds of both being down.
- Budget is only a chip in Down for...: its plans carry no price, so nothing is checked against it until a place is chosen, where Pick a place (lane D) uses each owner's budget locally.
- The residual risks of ADR 0120 hold: a missed plan when every resend of a lost confirmation is also lost; a dishonest friend probing free time within the run cap; the stub PSI revealing the starter's slots to friends with open requests.
- Phase 1's counters and the `decide` model call are gone. The starter builds the plan from answers the friend computed under its own limits, so a friend who answered can always accept it; anything else is refused in code.

## Sources

- Brief sections 2.6 (match before notify), 2.7 (mutual reveal, private aggregation), and 3.9 (PSI set sizes).
- ARCHITECTURE.md section 2 (rules 5 to 8) and section 7.
- ADRs 0011 (amendments 8 to 17), 0012 (amendment 8), 0014, 0017, 0019, 0020, 0021, 0120, 0121.
- The impossibility of guaranteed agreement over a lossy channel: E. A. Akkoyunlu, K. Ekanadham, R. V. Huber, "Some constraints and tradeoffs in the design of network communications," SOSP 1975, https://doi.org/10.1145/800213.806523
- `Packages/Skills/DownFor/` and its tests.
