# ADR 0207: Change the plan in the app

- Status: Proposed
- Date: 2026-10-03
- Owner: P15-A (Shell and IA)
- Builds on: ADR 0022 (Oliver's decision), ADR 0243 (lane E's protocol), ADRs 0018, 0201, 0206

## Context

ADR 0022 lets a confirmed plan change, and ADR 0243 says how lane E's `StarlingChangePlan` runs it on every phone. Lane E's requests 10 to 14 (`docs/requests/P15-E.md`) list what the app must do. A few choices were the shell's.

## Decision

1. **The plan's own interaction takes Change the plan's updates.** The service reports an agreed change as the updated plan, and a leave as `withdrawn`, on the interaction that holds the plan, which belongs to the skill that made it. The coordinator accepts exactly these from Change the plan, and only for a standing plan: the next revision of the same plan (same `Plan.origin`), or `withdrawn`. Any other skill naming another's interaction is still dropped. For every skill, a plan is recorded only as the next revision of the one stored, or the same plan again, a compare-and-set that serializes changes from different skills (P15-E request 15), and after any plan update the app tells Change the plan (`planDidChange`), so an open suggestion checks its basis still stands. Its delivery journal is on disk (`FileChangePlanJournal`).
2. **Plans are found by origin.** `StandingPlans` reads the coordinator's interactions and finds a plan by `Plan.origin`. Change the plan's lookup and Swap photos' both use it, so a friend added later, who holds the plan in their Change the plan interaction, is part of it.
3. **Change the plan starts only from a plan's detail.** It is never a tile in New or a routing choice. Core's `SkillFlags.phase1_5` lists it (PR #115), so the build's flags include it.
4. **The words are the app's, from the owner's nicknames.** Cards read "Maya suggests 8:30 PM instead of 8 PM", "dinner instead of boba", or "adding Jake", and an added friend reads "Maya asks you to join boba with Jake, tonight at 8 PM". The model never writes them, since they quote the plan as it stands on this phone.
5. **A change lives on its plan's timeline.**
   - **Agreed:** shown as "Changed to dinner" or "Added Jake", never as a plan of its own on Home.
   - **Not agreed:** the suggester reads "The plan stays as it was". A friend's suggestion that closed is left off the timeline, so nobody is named.
   - **Leaving:** reads "You left this plan" or "Maya left".
   - **An added friend:** their Change the plan interaction is the plan, and Home shows it as one.
6. **The buttons say why when they are off.**
   - **"Suggest a change"** names why it can't run: a suggestion is still open, someone's Starling can't change plans, the plan is used up or over, or the skill is off in You. The sheet says what the suggestion uses beyond the plan before "Suggest it", which is the approval, as for Keep it going.
   - **"Leave this plan"** asks once.
7. **A place reaches a plan only through lane E's planner, on every phone.** A finished Pick a place link moves the parent only through `ChainPlanner.parent(_:updatedBy:)`, saved by the coordinator at the parent's next revision. The owner's link names its parent; a friend's request finds it through the hint the coordinator grouped it by (the plan with that origin), so the friend's stored plan moves too (review of #118); plan detail shows the plan as stored and never replays a link's place into it (Codex review of PR #118). A yes to a place change is final once sent, so nothing rolls back.
8. **A yes to a change of place is final** (Orchestrator, ADR 0233). For a Pick a place on a plan that has a place, once the owner said yes, the app offers no "Not this one" and no "Take it back", and points to "Suggest a change" or "Leave this plan".
9. **"Update in Calendar".** A calendar hand-off remembers the plan revision it was made at. After a change, the plan's detail offers to add the new details. It says to remove the old event, because without calendar access the app cannot edit it (ADR 0018).

## Consequences

- **Known limits are lane E's (ADR 0243):** a lost confirmation leaves one phone's plan as it was, and two suggestions that cross both close without changing anything.

## Sources

- ADR 0022, ADR 0243, `docs/requests/P15-E.md` items 10 to 14, `docs/checklists/phase-1.5-P15-E.md` steps 13 to 18
- `App/Features/Sources/StarlingFeatures/StandingPlans.swift`, `ChangePlanWords.swift`, `PlanChanges.swift`, and `LifecycleCoordinator.changesThePlan`, with `ChangePlanWiringTests`
