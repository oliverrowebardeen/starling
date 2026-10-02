# ADR 0233: Pick a place on a plan needs everyone in it

- Status: Proposed
- Date: 2026-10-02
- Owner: P15-D (Pick a place)
- Builds on: ADRs 0022, 0230

## Context

ADR 0022 lets a confirmed plan change. Place and budget changes go through Pick a place on the same plan ("Somewhere else?"). Everyone in the plan must agree, a change that does not go through leaves the plan as it was, and nobody can remove someone else.

Before this, Pick a place on a plan worked like a fresh request (ADR 0230). It chose the place that fit the most friends, confirmed with whoever said yes, and produced that shorter roster. Lane E's `parent(updatedBy:)` then narrowed the parent plan to it, so a place change could drop people from a plan. The plan it built also kept the old revision.

## Decision

When a request carries a `Plan` input, Pick a place treats it as a change to that plan:

1. **Only the plan's people are asked.** Participants who are not in the plan are not asked: adding someone is a Change the plan suggestion. If anyone in the plan is not named or cannot run Pick a place, nobody could agree for them, so the request ends as unsupported before anything is sent.
2. **The place must fit everyone.** Only a place on every friend's list is proposed. If there is none, the request ends with no agreement, and no proposal is sent.
3. **Everyone must say yes.** The change is confirmed only when every friend accepts by the confirm deadline. Otherwise it ends with no agreement at the deadline, and everyone still waiting hears the ordinary no. A pass still looks like silence, as in ADR 0230.
4. **A yes taken back after the confirmation calls the change off for everyone.** The organizer ends as failed, and every other friend hears the ordinary no and ends as withdrawn. The links that carried the new place are no longer planned, so the plan stays as it was. Leaving the plan is Change the plan's job, not this skill's.
5. **The agreed plan is `Plan.updating(place:)`.** It has the same identifier, attendees, time, and activity, and a revision one higher (ADR 0022, decision 7).
6. **A new budget is the owner's limit for this search only.** It comes from the request's intent, as always, filters the candidates on the phone, and never leaves it. Nothing from an earlier pick on the plan carries over.
7. **After a restart,** an organizer knows it was changing a plan because its stored proposal's plan has a revision above 0. A plan built from the terms alone starts at 0.

Without a `Plan` input, for example after Find a time or from New, nothing changes: the most-friends rule of ADR 0230 still applies.

## Consequences

- A place change can no longer shrink a plan. Lane E's `parent(updatedBy:)` still accepts a narrower roster from a link, but Pick a place on a plan now only produces the full one.
- Lanes A and E apply the produced place with `Plan.updating(place:)`. Rebuilding the plan with `Plan(...)` would reset its revision to 0.
- A plan with one friend whose phone lacks Pick a place cannot change its place until that phone is updated.

## Sources

- ADR 0022 and the Orchestrator's instruction for lane D, 2026-10-02
- Tests: `Packages/Skills/PickAPlace/Tests/PickAPlaceTests/PlanChangeTests.swift`
