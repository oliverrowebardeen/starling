# ADR 0207: Change the plan in the app

- Status: Accepted (code merged on main; status updated 2026-10-06)
- Date: 2026-10-03
- Owner: P15-A (Shell and IA)
- Builds on: ADR 0022 (Oliver's decision), ADR 0023 (one change per plan), ADR 0243 (lane E's protocol), ADRs 0018, 0201, 0206

## Context

ADR 0022 lets a confirmed plan change, and ADR 0243 says how lane E's `StarlingChangePlan` runs it on every phone. Lane E's requests 10 to 14 (`docs/requests/P15-E.md`) list what the app must do. A few choices were the shell's.

## Decision

1. **The plan's own interaction takes Change the plan's updates.** The service reports an agreed change as the updated plan, and a leave as `withdrawn`, on the interaction that holds the plan, which belongs to the skill that made it. The coordinator accepts exactly these from Change the plan, and only for a standing plan: the next revision of the same plan (same `Plan.origin`), or `withdrawn` for the interaction holding a plan being left: the plan's holder by origin, with the owner's leave chained to it or a friend's departure grouped under it on record. Any other skill naming another's interaction is still dropped. For every skill, a plan is recorded only as the next revision of the one stored, or the same plan again, a compare-and-set that serializes changes from different skills (P15-E request 15), and after any plan update the app tells Change the plan (`planDidChange`), so an open suggestion checks its basis still stands. Its delivery journal is on disk (`FileChangePlanJournal`).
2. **Plans are found by origin, in memory.** `StandingPlans` reads the coordinator's interactions and finds a plan by `Plan.origin`. Change the plan's, Swap photos', and Pick a place's lookups all use it, so a friend added later, who holds the plan in their Change the plan interaction, is part of it, and no skill checks a change against a plan the interaction store has not caught up with (review of #118).
3. **Change the plan starts only from a plan's detail.** It is never a tile in New or a routing choice. Core's `SkillFlags.phase1_5` lists it (PR #115), so the build's flags include it.
4. **The words are the app's, from the owner's nicknames.** Cards read "Maya suggests 8:30 PM instead of 8 PM", "dinner instead of boba", or "adding Jake", and an added friend reads "Maya asks you to join boba with Jake, tonight at 8 PM". The model never writes them, since they quote the plan as it stands on this phone.
5. **A change lives on its plan's timeline.**
   - **Agreed:** shown as "Changed to dinner" or "Added Jake", never as a plan of its own on Home.
   - **Not agreed:** the suggester reads "The plan stays as it was". A friend's suggestion that closed is left off the timeline, so nobody is named.
   - **A place step that finds nobody up:** a Pick a place on the plan (the owner's step or a friend's request grouped under it) that ends with nobody up reads the same, "The plan stays as it was", since the plan still stands unchanged. That is its status everywhere it is listed: Home, a friend's History, the request's detail, and the timeline. It never reads "No plan this time".
   - **Leaving:** reads "You left this plan" or "Maya left".
   - **An added friend:** their Change the plan interaction is the plan, and Home shows it as one.
6. **The buttons say why when they are off.**
   - **"Suggest a change"** names why it can't run: another change to the plan is in progress, someone's Starling can't change plans, the plan is used up or over, or the skill is off in You. The sheet says what the suggestion uses beyond the plan before "Suggest it", which is the approval, as for Keep it going. The tap approves only the row the sheet showed: if the row adds more by then, lane E refuses it, nothing starts, and the sheet asks the owner to check again.
   - **"Leave this plan"** asks once.
7. **A place reaches a plan only through lane E's planner, on every phone.** A finished Pick a place link moves the parent only through `ChainPlanner.parent(_:updatedBy:)`, saved by the coordinator at the parent's next revision. Lane E's `parent(updatedBy:in:)` finds the parent: the owner's link names it, and a friend's request is matched through the hint the coordinator grouped it by, so the friend's stored plan moves too (review of #118); plan detail shows the plan as stored and never replays a link's place into it (Codex review of PR #118). A yes to a place change is final once sent, so nothing rolls back.
8. **A yes to a change of place is final** (Orchestrator, ADR 0233). For a Pick a place on a plan that has a place, once the owner said yes, the app offers no "Not this one" and no "Take it back", and points to "Suggest a change" or "Leave this plan".
9. **One change per plan at a time** (ADR 0023). The app creates one `PlanChangeHolds` in `LiveServices` and `DebugServices` and passes it to Pick a place and Change the plan. `PlanChangesInProgress` keeps each plan's holder on the main actor, following `PlanChangeHolds.updates()` from launch, so a hold or release reaches the cards at once. While another change holds a plan, or a suggestion for it is open, "Suggest a change" and a Keep it going step that changes the plan are off with "Another change to this plan is in progress." A friend's card for a second change offers no yes and says the same line; its no still goes, since a no needs no hold. A start the skill refuses because the plan is held (lane E's `planBusy`, lane D's `planChangeInProgress`) is `StartRefusal.planChangeInProgress` and reads the same. The coordinator records a yes before the skill sees it, and the skill keeps a refused yes's card open, so Home answers through `AppModel.answer`, which asks the holds first and leaves the card as it was while another change holds the plan. Two changes that cross both end as "The plan stays as it was" for each suggester (decision 5).
10. **"Update in Calendar".** A calendar hand-off remembers the plan revision it was made at. After a change, the plan's detail offers to add the new details. It says to remove the old event, because without calendar access the app cannot edit it (ADR 0018).

## Consequences

- **Known limits are lane E's (ADR 0243):** a lost confirmation leaves one phone's plan as it was, and two suggestions that cross both close without changing anything.

## Sources

- ADR 0022, ADR 0243, `docs/requests/P15-E.md` items 10 to 14, `docs/checklists/phase-1.5-P15-E.md` steps 13 to 18
- `App/Features/Sources/StarlingFeatures/StandingPlans.swift`, `ChangePlanWords.swift`, `PlanChanges.swift`, and `LifecycleCoordinator.changesThePlan`, with `ChangePlanWiringTests`
