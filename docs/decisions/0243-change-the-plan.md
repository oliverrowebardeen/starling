# ADR 0243: Change the plan: the protocol on every phone

- Status: Proposed
- Date: 2026-10-03
- Owner: P15-E (Chaining and audit)
- Builds on: ADR 0022 (Oliver's decision), ADRs 0011, 0012, 0019, 0020, 0021, 0240, 0241

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
   - **Confirmation.** When all have said yes, the suggester sends each one a confirmation that names their offer and carries no values. On receiving it, each phone applies the change to its own plan, revision one higher. The suggester applies it once the confirmations have gone out.
   - **No agreement.** If the window closes first, nothing changes. The suggester's card ends with nobody up, which the app shows as "The plan stays as it was"; everyone else's card just closes (expired).
3. **The revision travels in `Proposal.round`.** Core has no field for the revision a suggestion changes. A new issue key would raise a consent sheet on every send, because the policy asks about any issue no topic covers. `round` is validated, bounded, and outside every topic.
   - A receiver ignores an offer whose round is not its plan's revision.
   - The cost is that a plan can change at most 15 times; `ChainPlanner.changeOffer` stops offering changes at `maxChangeableRevision`.
   - `docs/requests/P15-E.md` asks Core for a proper field.
4. **Plans stay in step on every phone.**
   - **Where the update lands.** The service reports the updated plan as `.produced(planInteraction, .plan(...))` for the interaction that holds the plan on that phone. `planLookup` finds that interaction by `Plan.origin`.
   - **Place changes too.** `ChainPlanner.parent(_:updatedBy:)` now raises the revision through `Plan.updating`, applies a friend's grouped Pick a place link as well as the owner's own, and changes nothing when applied twice. Otherwise a place agreed on a friend's request would never reach this phone, and revisions would drift apart.
5. **One suggestion per plan at a time.**
   - `changeOffer` is not offered while one is open, whether the owner's own or a friend's.
   - A friend's suggestion that arrives while another is open waits (up to four per plan). When the open one settles, it is shown only if its window is still open and the plan's revision has not moved.
   - The suggester can withdraw: everyone already asked is told, and their cards close.
6. **Adding a friend: everyone agrees, then the friend.**
   - **Asking.** Only the suggester's own friends whose card runs the skill can be added (`beginChange` checks).
   - **The invite.** After all yeses, the friend gets an invite with the plan as it will be: activity, time, place, and the roster under people. With people at Ask me, the suggester sees a consent sheet for it; with Never, the friend cannot be added.
   - **Joining.** When the friend accepts, the suggester confirms to everyone, the friend included, and the roster updates on every phone.
   - **What the friend holds.** On the friend's phone the plan lives in the interaction that brought them in. Its `Plan.origin` is the plan's conversation, so chains link by the plan's origin (`Interaction.planConversation`) rather than by the root's own conversation; for every plan agreed so far the two are the same.
7. **Leaving needs no agreement and discloses nothing.**
   - **The notice.** The leaver sends each other person a reject in a fresh conversation chained to the plan, carrying no values, so no consent sheet appears. The leaver's plan ends withdrawn, after its conversation is retired.
   - **The others.** Each other phone shows the leave as an ended entry on the plan's timeline and shrinks its plan, or ends it withdrawn if only that phone is left.
   - **During a suggestion.** Leaving ends any suggestion open for that plan quietly, since its roster changed.
8. **The rules from ADRs 0011 and 0021 hold throughout.**
   - Every state a reply is matched against is registered before the send that could prompt it (issue #105).
   - An offer's message ID is known only once Outbox returns, so a yes that arrives first is held until it is, then counted only if it names that offer.
   - Every ending retires the conversation through `Outbox.retire` before any event is published. A refused retirement reports the ending as failed.
   - Incoming requests are checked against the ledger.
   - Every send names its interaction in `OutboundContext`, so the egress journal and the audit record it on the change, which shows on the plan's timeline.
9. **Restart.** An open suggestion cannot be resumed, since its offers' IDs are not stored. It is retired and reported failed, and the plan stays as it was.

## Consequences

- Lane A builds "Suggest a change" (`changeOffer`, then `beginChange`) and "Leave this plan" (`beginLeave`) on the plan's detail.
  - It applies `.produced` and `.lifecycle` events that name the plan's interaction.
  - It shows a finished change, which ends planned, on the plan's timeline rather than as a plan of its own.
  - It words a change that ended with nobody up as "The plan stays as it was".
- **Known limits, best-effort delivery (ARCHITECTURE rule 5):**
  - A confirmation that never arrives leaves that phone's plan as it was while the others changed.
  - Two suggestions that cross usually both close without changing anything, and the owner can suggest again.
  - Both are stated here, and lane F tests them.

## Sources

- ADR 0022 and Oliver's answers, 2026-10-02
- ADRs 0011 (amendments 13 to 16), 0017, 0019 (amendment 10), 0020, 0021; issue #105
- `Packages/Skills/ChangePlan` and `Packages/StarlingChaining/Sources/StarlingChaining/ChangingAPlan.swift`, with their tests
