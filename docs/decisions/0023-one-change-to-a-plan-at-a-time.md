# ADR 0023: One change to a plan at a time

- Status: Accepted
- Date: 2026-10-05
- Owner: Orchestrator
- Builds on: ADR 0022; lane ADRs 0233 (Change the place) and 0243 (Change the plan)

## Context

ADR 0022 lets anyone in a confirmed plan suggest a change, and the change applies only when everyone agrees. Two skills make changes: Change the plan (time, activity, people) and Pick a place on the plan (place, with a budget for the search). Each change names the plan revision it changes, and a phone applies a change only over that revision.

The second review of lane D's PR #118 found that this is not enough when two changes are open at once. Maya suggests 8:30 while Jake picks a new place, both over revision 3:

- Every friend says yes to both, because neither has applied yet and both still name revision 3.
- Both reach everyone's yes, and each phone applies whichever confirmation arrives first as revision 4.
- The second is then over the wrong revision and is ignored, so phones that heard them in different orders end on different plans.

The revision check catches a stale change. It cannot choose between two fresh ones.

## Decision

1. **A phone takes part in one change per plan at a time.** Before a phone starts a change (sends its first offer or request) or says yes to one, it holds the plan for that change. While another change holds the plan, it neither starts a new one nor says yes.
2. **Every skill that changes a plan uses the same holds.** That is Change the plan, Pick a place on a plan (a first place as well as a change of place), and any later skill whose result updates a plan. The app creates one `PlanChangeHolds` and passes it to each.
3. **A plan is named by `Plan.origin`.** Both skills already find plans by it.
4. **The hold ends with the change.** The skill releases it on every ending: planned, nobody up, expired, withdrawn, failed, and, on a friend's phone, when the card closes. Leaving the plan needs no hold, because it needs no agreement; it changes the roster, so an open change then fails its revision check.
5. **Holds live in memory.** After a relaunch, each skill holds the plan again for every change it restores. A change that finds the plan held by another ends as "The plan stays as it was". Before a relaunch at most one change held each plan, so this happens only with state saved before this ADR.
6. **What the owner sees.**
   - Two changes that cross both end without changing anything, and each suggester sees "The plan stays as it was". Lane E already words crossing suggestions this way (ADR 0243).
   - A friend asked about a second change while the first is open sees that another change to this plan is in progress, not a choice that would be ignored. Lane A words it.

## Consequences

- Two changes at the same moment can no longer leave phones on different plans: at most one of them can collect everyone's yes, because each suggester holds the plan for its own change and so cannot say yes to the other.
- A busy plan can turn away a second suggestion until the first ends. That is the cost of every phone agreeing on one plan.
- Lanes D and E hold and release in their services and re-hold on restore; lane A creates the holds in `LiveServices` and `DebugServices` and words the "in progress" state.

## Not covered

The organizer of a change is trusted to report that everyone agreed (ADR 0243). A friend's phone cannot verify another friend's yes, because friends in a plan are often not paired with each other. Holds stop honest phones from diverging; they do not stop a paired friend who lies.

## Sources

- Second review of PR #118, 2026-10-05
- ADR 0022; lane ADRs 0233 and 0243
- `Packages/StarlingCore/Sources/StarlingCore/PlanChangeHolds.swift` and its tests
