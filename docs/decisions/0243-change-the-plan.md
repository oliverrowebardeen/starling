# ADR 0243: Change the plan: the protocol on every phone

- Status: Accepted (code merged on main; status updated 2026-10-06)
- Date: 2026-10-03
- Owner: P15-E (Chaining and audit)
- Builds on: ADR 0022 (Oliver's decision), ADR 0023 (one change to a plan at a time), ADRs 0011, 0012, 0019, 0020, 0021, 0240, 0241

## Context

ADR 0022 lets a confirmed plan change. Anyone in it can suggest a new time, activity, or friend to add. The change applies on every phone only when everyone else says yes. A plan that does not change "stays as it was", and nobody is named. Anyone can leave without asking, and nobody removes anyone else. Core gives `Plan.revision`, `Plan.updating(...)`, `SkillID.changePlan`, and `ChainTrigger.whilePlanned`.

Left open for this lane:

- what travels between phones;
- how every phone learns that everyone agreed;
- where a suggestion names the revision it changes;
- how the plan held by another skill's interaction is updated;
- what an added friend holds.

## Decision

1. **A skill package, `Packages/Skills/ChangePlan`** (module `StarlingChangePlan`).
   - The descriptor: invite only, `whilePlanned`, accepts and produces a plan. It uses time, activity, and people, and requires none (ADR 0019 decision 7), so no Never setting blocks it.
   - `PlanChange` is a change (time, activity, a friend to add, or several) or leaving. It is encoded into the request that `ChainPlanner.beginChange` and `beginLeave` build: time as one `within` window, activity as one liked keyword, a friend as the plan's roster plus them, and leaving as `mustBe(false)` on people.
2. **The suggester coordinates** (star, not mesh):
   - **Offer.** The suggester sends each other person one offer with only what changes: time slots, activity keywords, or the new roster under people.
   - **Yes or no.** A yes goes back to the suggester alone: an acceptance of exactly the offered terms, with the offer in `OutboundContext.accepting` (ADR 0019 amendment 10). A no sends nothing, so it looks like silence (ADR 0017).
   - **Confirmation.** When all have said yes, and only if the plan still stands at the suggestion's basis (revision and people), the suggester applies the change and sends each one a confirmation that names their offer and carries no values. A receiver applies it to its own plan, revision one higher, only if its plan still has that basis, or that basis with only leaves since (decision 7).
   - **Delivered until acknowledged** (Orchestrator's review of PR #111). Each receiver acknowledges a confirmation once it has applied it, with a value-free accept naming its offer, and acknowledges a resent one again. The suggester resends to everyone who has not acknowledged: at once, then after 5 seconds doubling to 5 minutes (like Down for's delivery), each wait measured from the attempt before it, so a slow round of sends or a late-running task never pushes the next one back (issue #130), until all have or the plan's time has passed (at least 15 minutes from the first send; 24 hours for a plan without a time). Applying is idempotent by revision: a confirmation for the revision already applied changes nothing but is acknowledged; one that does not follow the phone's revision is ignored.
   - **A recipient's own yes comes first.** A confirmation that arrives while the recipient's yes is still going out is held until the yes is recorded (finding E).
   - **A yes waits for its confirmation** (Codex re-review of PR #111, finding 1; issue #116). A yes is journaled before it is sent, and the card keeps waiting for the confirmation until confirmation delivery would end (the resend bound above), not just until its decision window closes. A restart brings it back.
   - **The hold ends with the window** (final review of PR #111, finding 3). The suggester commits only within its window, so a confirmation can be late only by delivery. A yes holds the plan (decision 5) until a grace after the window (`ResendSchedule.holdGrace`, 15 minutes); then the card ends expired and the plan is free. The yes stays journaled, and a confirmation that still comes applies if the plan allows it, acknowledged in a fresh conversation.
   - **Committing** (finding 2). Once everyone has said yes, the suggester enters a committing step before anything suspends, so a withdrawal from then on aborts the commit. It journals the agreed plan, then re-reads the plan and checks that the suggestion is still its own, and only then publishes and sends.
   - **Withdrawing.** The suggester can withdraw. From that moment, before anything is sent, no yes counts; the notices go to everyone asked so far (finding B).
   - **Withdrawals are delivered until acknowledged** (final review of PR #111, finding 3). A suggestion journals who it asked and each offer as its send returns. Every ending without a change withdraws each offer that went out, including after a send that failed partway and an offer whose send returns after the ending; after a restart, the journal's open suggestion is withdrawn. Each withdrawal goes in a fresh conversation, names its offer, and is resent until acknowledged or the grace after the window ends. The delivery stays open until every offer's send has returned, so one still sending is withdrawn too. A friend acknowledges one for an offer it never got.
   - **No agreement.** If the window closes first, nothing changes. The suggester's card ends with nobody up, which the app shows as "The plan stays as it was". The suggester tells everyone asked, so a card that said yes closes then too; everyone else's card just closes (expired).
3. **The revision travels in `Proposal.round`, and the roster asked in `inReplyTo`.** Core has no field for the revision a suggestion changes. A new issue key would raise a consent sheet on every send, because the policy asks about any issue no topic covers. `round` is validated, bounded, and outside every topic.
   - A receiver ignores an offer whose round is not its plan's revision.
   - The cost is that a plan can change at most 15 times; `ChainPlanner.changeOffer` stops offering changes at `maxChangeableRevision`. The Orchestrator accepted this for Phase 1.5 (request 2c stays open).
   - The offer's `inReplyTo` is `ChangePlanService.rosterDigest`: a digest of the plan's origin, the revision, the suggester, and everyone asked. A receiver computes it from its own plan and ignores an offer put to fewer than everyone else in it. It discloses nothing a receiver does not hold (finding G).
   - `docs/requests/P15-E.md` asks Core for a proper field.
4. **Plans stay in step on every phone.**
   - **Where the update lands.** The service reports the updated plan as `.produced(planInteraction, .plan(...))` for the interaction that holds the plan on that phone. `planLookup` finds that interaction by `Plan.origin`.
   - **Place changes too.** `ChainPlanner.parent(_:updatedBy:)` applies a friend's grouped Pick a place link as well as the owner's own, and `parent(updatedBy:in:)` finds the plan a friend's request updates through its hint, since it has no chain (review of PR #118). Otherwise a place agreed on a friend's request would never reach this phone, its plan would fall a revision behind, and its next place step would start as a first place.
     - **Bound to a revision** (findings 5 and 6, issue #119, and the review of PR #118). Each phone's agreed plan (`SkillProposal.plan`, from Pick a place, ADR 0233) names the revision it makes. A result applies only when that is the plan's next revision, and the plan keeps it. A result over an older revision, or one already applied, changes nothing; it is never narrowed onto the plan as it stands now.
     - **Whole.** It applies only once both final artifacts, the place and the roster, are in, together, in whichever order they arrive. A roster published after that (a first place someone left) does not move the plan again.
     - A yes to a change of place is final once sent (Orchestrator's decision on #118), so no place result is rolled back.
   - **Who a place result may narrow the plan to** (Orchestrator's decision on issue #66 and finding D).
     - This phone's own place link (it organized the step and saw who accepted) applies the place and narrows the roster to those who accepted. Nobody is removed by someone else: each person left out was asked and did not accept.
     - A friend's place link, grouped under the plan only by its hint, applies only if its roster is the plan's whole current roster, and never removes anyone: grouping is not authority to change the plan.
   - **One basis at a time** (finding C). Before inviting an added friend and before confirming, the suggester re-reads the plan; if another skill moved it, the suggestion ends as "The plan stays as it was" and everyone asked is told. `planDidChange(_:)` lets the coordinator end such a suggestion as soon as it applies another skill's update. Serializing with those updates needs the coordinator to apply a `.plan` only exactly one revision above the stored one (`docs/requests/P15-E.md`).
5. **One suggestion per plan at a time.**
   - **Holds** (ADR 0023). The service takes the app's `PlanChangeHolding`, shared with Pick a place. The suggester holds the plan before its first offer, and each friend before its yes. While another change holds the plan, from either skill, a suggestion does not start and a yes is not given: both throw `ChangePlanError.planBusy`, and the card stays open so the app can say another change is in progress. Every ending releases the hold: planned, nobody up, expired, withdrawn, passed, failed. A restored yes holds the plan again until its grace ends (decision 2), and if another change holds it, the card ends with no change. Leaving takes no hold.
   - `changeOffer` is not offered while one is open, whether the owner's own or a friend's.
   - A friend's suggestion that arrives while another is open waits (up to four per plan). When the open one settles, it is shown only if its window is still open and the plan's revision has not moved.
   - The suggester can withdraw: everyone already asked is told, and their cards close.
6. **Adding a friend: everyone agrees, then the friend.**
   - **Asking.** Only the suggester's own friends whose card runs the skill can be added (`beginChange` checks).
   - **The invite.** After all yeses, the friend gets an invite with the plan as it will be: activity, time, place, and the roster under people. With people at Ask me, the suggester sees a consent sheet for it; with Never, the friend cannot be added.
   - **Only a real invite opens a card** (final review of PR #111, finding 4). A phone without the plan reads an offer as an invite only if it names no asked roster (every offer to a member carries one) and this phone is last in its roster, where the suggester puts the friend it adds. So someone who left never reads the members' offer as an invite back in. The suggester counts a yes only from someone in the plan as it stands, or the friend.
   - **Joining.** When the friend accepts, the suggester confirms to everyone, the friend included, and the roster updates on every phone.
   - **What the friend holds.** On the friend's phone the plan lives in the interaction that brought them in. Its `Plan.origin` is the plan's conversation, so chains link by the plan's origin (`Interaction.planConversation`) rather than by the root's own conversation; for every plan agreed so far the two are the same.
7. **Leaving needs no agreement and discloses nothing.**
   - **The notice is its own message** (finding A): an offer of nothing, bound to the plan by `chainedFrom` and to the revision the owner left at by `round`, with its ID in `inReplyTo`. It carries no values, so no consent sheet appears. A rejection is never read as a leave: it only withdraws an offer it names, open or queued. The leaver's plan ends withdrawn, after its conversation is retired.
   - **Delivered until acknowledged.** Each notice attempt goes in a fresh conversation; each receiver applies it once (from someone in its plan, at a revision it has reached), acknowledges it, and acknowledges a resent one again. The leaver resends on the same schedule as confirmations.
   - **The others.** Each other phone shows the leave as an ended entry on the plan's timeline and shrinks its plan, or ends it withdrawn if only that phone is left. A confirmation owed to the leaver is no longer owed. A departure is reserved before the first suspension, so two copies of one notice apply it once.
   - **A leave and a committed change commute** (final review of PR #111, finding 1). A leave still raises the revision, but it never closes a card that already said yes, since that change may have been committed. Such a card's confirmation applies over its basis, or over its basis with only leaves since (each journaled here as a departure, one revision each): the change's own fields over the smaller roster, one revision higher. Whichever order a leave and a confirmation reach a phone, every phone ends on the same plan and revision.
   - **A friend added while someone leaves** (re-review of PR #111). The leaver's notices go to the plan they knew, without a friend the racing change adds. The suggester passes such a departure on to that friend: when it applies a departure from someone still owed its confirmation, at a revision before the change, it sends the friend a counter with no values, whose `inReplyTo` is a digest of the plan, the revision left at, and the leaver (`ChangePlanService.departureDigest`). The friend finds the leaver by computing it for each person in its own plan, so nothing is disclosed. It counts only from the suggester who added the friend, for a revision at or before the one the friend joined over, so nobody else can tell the friend someone left. It is journaled, acknowledged, and resent like a leave notice.
   - **On an added friend's phone** the plan lives in the change that added them, whose conversation is not the plan's origin. A plan ends only after both conversations are retired.
   - **During a suggestion.** Leaving ends any suggestion open for that plan quietly, since its roster changed.
8. **The rules from ADRs 0011 and 0021 hold throughout.**
   - Every state a reply is matched against is registered before the send that could prompt it (issue #105).
   - An offer's message ID is known only once Outbox returns, so a yes that arrives first is held until it is, then counted only if it names that offer.
   - Every ending retires the conversation through `Outbox.retire` before any event is published. A refused retirement reports the ending as failed.
   - Incoming requests are checked against the ledger.
   - Every send names its interaction in `OutboundContext`, so the egress journal and the audit record it on the change, which shows on the plan's timeline.
9. **Restart.** A `ChangePlanJournal` the app keeps on disk holds typed values only:
   - each yes still waiting for its confirmation;
   - confirmations still owed acknowledgments, with the agreed plan and the interaction that holds it;
   - each change this phone applied, with the plan it applied;
   - leave notices still owed acknowledgments, including departures passed on to an added friend;
   - each suggestion still asking, with who it asked and the offers sent, and withdrawals still owed acknowledgments;
   - who this phone saw leave, and the revision their leaving applied to.

   Delivery picks up after a restart on either side. A commit or update that the crash interrupted (the journal has it, the plan does not show it) is replayed: the suggester's when the plan still stands one revision below, a receiver's and a departure's when the plan still stands where it found it.
   - **A commit is resent only if it applied here** (final review of PR #111, finding 5). The commit's record is written before its last basis check, so it may hold a commit that never applied. Restore finishes and resends one only if the change ended planned, the plan shows it, or the plan still stands at the basis and the change was not withdrawn. Any other becomes a withdrawal to everyone still owed a confirmation, and the suggester's card ends as "The plan stays as it was".
   - **A leave the crash interrupted ends on restart** (finding 2): the leave and this phone's plan end withdrawn, each after its conversation is retired, and the notices still owed go out again.
   - **An open suggestion still asking** cannot be resumed: it is retired and reported failed, the plan stays as it was, and each offer it journaled is withdrawn (decision 2).
10. **The record comes first** (issue #117). A record a restart would need is written before the action it recovers, and if it cannot be, the action does not happen:
    - a yes or a leave that cannot be recorded throws `ChangePlanError.journalUnavailable` and sends nothing;
    - a commit that cannot be recorded ends with nobody up, and the plan stays as it was;
    - a confirmation or departure that cannot be recorded is neither applied nor acknowledged, so the next resend tries again;
    - a receiver acknowledges only after its applied record, which carries the plan, is durable, and acknowledges a resend only once the plan shows the change (replaying it otherwise).

## Consequences

- Lane A builds "Suggest a change" (`changeOffer`, then `beginChange`) and "Leave this plan" (`beginLeave`) on the plan's detail.
  - It applies `.produced` and `.lifecycle` events that name the plan's interaction.
  - It shows a finished change, which ends planned, on the plan's timeline rather than as a plan of its own.
  - It words a change that ended with nobody up as "The plan stays as it was".
- **Known limits:**
  - **The suggester is trusted to report that everyone agreed, as the organizer of any group step is** (finding G). Attendees are often not paired with each other, so a phone cannot verify another attendee's yes. What it can check, it does: the offer names everyone asked, and the confirmation is applied only on the basis it was made for. The Orchestrator adds this to the threat model.
  - **The suggester who added a friend can tell that friend's phone that another member left** (re-review of PR #111). The departure it passes on (decision 7) names the leaver by a digest of values the suggester knows (the plan, the revision, and the leaver), and the friend cannot verify that the leaver really left. Only that friend's phone is affected, only for a revision at or before the one it joined over, and an honest phone never sends one for someone who did not leave. It falls under the paired friend who lies (ADR 0023, Not covered). The Orchestrator adds it to the threat model.
  - Two suggestions that cross usually both close without changing anything; the owner can suggest again (accepted).
  - A phone that stays unreachable until the plan's time has passed never receives the confirmation or notice and keeps its plan as it was. Resending stops then because the plan is over.
  - Until Pick a place names the revision on every phone's agreed plan (PR #118), no place result applies.
  - When a friend organized a place step and someone passed, this phone's plan does not take that place, so its plan can differ from the organizer's. The follow-up after this PR: Pick a place carries the asked-roster digest (decision 3) on requests chained from a plan, and a friend's narrowed result is accepted when that digest equals this phone's whole roster, trusting the organizer for who accepted, as above.

## Sources

- ADR 0022 and Oliver's answers, 2026-10-02
- ADRs 0011 (amendments 13 to 16), 0017, 0019 (amendment 10), 0020, 0021; issue #105
- `Packages/Skills/ChangePlan` and `Packages/StarlingChaining/Sources/StarlingChaining/ChangingAPlan.swift`, with their tests
