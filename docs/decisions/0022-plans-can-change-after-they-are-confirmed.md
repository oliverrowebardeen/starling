# ADR 0022: Plans can change after they are confirmed

- Status: Accepted (Oliver, 2026-10-02)
- Date: 2026-10-02
- Owner: Orchestrator
- Builds on: ADRs 0011, 0012, 0019, 0020, 0021

## Context

After his two-phone test on 2026-10-02, Oliver asked for confirmed plans to be editable: anyone in the plan can suggest a change, for example to the budget, place, or people, and it must work well.

Asked about the open points, he chose:

- **Everyone in the plan must agree.** A change applies only if every person in the plan says yes.
- **If a change does not go through,** the person who suggested it sees only "The plan stays as it was". Nobody is named, the same quiet rule as passing on a request.
- **People:** anyone can suggest adding a friend, and anyone can leave. Nobody can remove someone else.

Starling already has the pieces:

- Chaining runs a new interaction on a confirmed plan with its own consent (ADR 0012). Pick a place already updates a plan's place.
- Revision-bound answers keep a tap on old terms from accepting new ones (ADR 0011).
- The ledger, the audit, and retirement cover every send (ADR 0021).

## Decision

1. **A change is its own chained skill, `change_plan`.** It is started by the owner from the plan's detail, any time after the plan is confirmed and before it ends (`ChainTrigger.whilePlanned`). It accepts the plan and produces the updated plan.
   - Each suggestion is one interaction in its own conversation, chained to the plan. It gets the lifecycle, consent for what it reveals, the ledger, retirement, and the audit for free.
2. **What can change:** the time, the activity, and the people (adding a friend).
   - A change of place, or a new budget, goes through Pick a place on the same plan ("Somewhere else?"), which already updates the plan's place. A budget is a limit for choosing a place, not a term of the plan.
3. **Everyone must agree.**
   - The suggestion goes to everyone else in the plan as an Invite card: "Maya suggests 8:30 instead of 8". Each person accepts or declines.
   - The change applies on every phone only when all of them accept, as `Plan.updating(...)` with the revision one higher.
   - A suggestion names the plan revision it changes. An answer to an older revision never applies.
4. **When a change does not go through**, because someone declines or the window closes:
   - Nothing changes.
   - The suggester's card says "The plan stays as it was", naming nobody.
   - Every other card simply closes. A decline looks like silence, as in ADR 0017.
5. **People.**
   - **Adding a friend** is a change like any other. Everyone in the plan agrees first; then that friend gets an Invite for the plan, and the roster updates once they accept. The friend sees the roster only under the people topic (ADR 0019), and only friends of the suggester can be added.
   - **Leaving** needs no agreement. The leaver's plan ends, withdrawn, and the others' plans update to the smaller roster. A plan left with one person ends for that person too.
   - **Nobody can remove someone else.**
6. **One suggestion at a time per plan.**
   - While one is open, another person's suggestion waits until it settles.
   - The suggester can withdraw their own suggestion.
7. **The plan's revision is part of `Plan`.** It starts at 0 when the plan is agreed and rises by one for each agreed change, including a new place from Pick a place. Plans saved before this decode at 0.
8. **After a change, the hand-offs follow.**
   - The plan's timeline shows the change.
   - What left your phone lists what the suggestion revealed.
   - Add to Calendar offers the updated details again.

## Consequences

- **Core** gains `SkillID.changePlan`, `ChainTrigger.whilePlanned`, `Plan.revision`, and `Plan.updating(attendees:activity:time:place:)`.
- **Lanes:**
  - E: builds the Change the plan skill and its chaining rules.
  - A: builds "Suggest a change" and "Leave this plan" in the plan's detail, the incoming suggestion cards, and the updated hand-offs.
  - D: checks that Pick a place updates an existing plan's place, including with a new budget.
  - F: tests forged, stale, and concurrent suggestions; suggestions from outside the plan; partial agreement; and privacy when adding a friend.

## Sources

- Oliver's request and answers in conversation, 2026-10-02
- ADRs 0011, 0012, 0017, 0019, 0020, 0021
