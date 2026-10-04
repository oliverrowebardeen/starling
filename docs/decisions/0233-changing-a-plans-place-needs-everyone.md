# ADR 0233: Changing a plan's place needs everyone in it

- Status: Proposed
- Date: 2026-10-02
- Owner: P15-D (Pick a place)
- Builds on: ADRs 0022, 0230

## Context

ADR 0022 lets a confirmed plan change. Place and budget changes go through Pick a place on the same plan ("Somewhere else?"). Everyone in the plan must agree, a change that does not go through leaves the plan as it was, and nobody can remove someone else.

Before this, Pick a place on a plan worked like a fresh request (ADR 0230). It chose the place that fit the most friends, confirmed with whoever said yes, and produced that shorter roster. Lane E's `parent(updatedBy:)` then narrowed the parent plan to it, so a place change could drop people from a plan. The plan it built also kept the old revision.

## Decision

A request with a `Plan` input runs on that plan. Two cases differ.

**A plan that already has a place: changing the place ("Somewhere else?").**

1. **The place must fit everyone.** Only a place on every friend's list is proposed. If there is none, the request ends with no agreement, and no proposal is sent.
2. **Everyone must say yes.** The change is confirmed only when every friend accepts by the confirm deadline. Otherwise it ends with no agreement at the deadline, and everyone still waiting hears the ordinary no. A pass still looks like silence, as in ADR 0230.
3. **Everyone must be able to say yes.** If anyone in the plan is not named or cannot run Pick a place, nobody could agree for them, so the request ends as unsupported before anything is sent.
4. **A yes is final once sent** (the Orchestrator's decision on the review of #118, as in Change the plan).
   - A friend cannot pass or withdraw after their yes has gone (`PickAPlaceError.yesIsFinal`).
   - A withdrawal that arrives after everyone said yes is ignored.
   - Nobody calls a confirmed change off, the organizer included.
   - Someone who changes their mind suggests another change, or leaves the plan through Change the plan. No rollback is needed.
5. **Every phone checks the change against its own plan.** A friend looks up its own copy of the plan the request names, through the service's `plans` lookup, and records what the request is before answering.
   - A proposal must name the plan's whole roster and the revision after the plan's own; anything else is not shown.
   - A confirmation must name the whole roster.
   - A shorter roster or a call-off after the confirmation changes nothing.
   - A request naming a plan this phone does not hold changes no plan here.
6. **The agreed plan is `Plan.updating(place:)`.** It has the same identifier, attendees, time, and activity, and a revision one higher (ADR 0022, decision 7).

**A plan with no place yet: its first place.** This is usually Keep it going after Down for….

7. **The first place works as before.** It goes ahead with the friends it fits and who say yes, and the others drop out of the plan (ADR 0230; lane E's chain rule).
   - Nobody is removed by someone else: each person left out either passed, said no, or could not do any of the places.
   - The agreed plan is `Plan.updating(attendees:place:)`, so its revision still rises.

**Both cases.**

8. **Only the plan's people are asked.** Participants who are not in the plan are not asked: adding someone is a Change the plan suggestion.
9. **A new budget is the owner's limit for this search only.** It comes from the request's intent, as always, filters the candidates on the phone, and never leaves it. Nothing from an earlier pick on the plan carries over.
10. **Every phone names the plan's new revision.**
   - The organizer's proposal carries it in `Proposal.round`, as Change the plan does until Core has a field for it (P15-E request 2c).
   - Each phone's agreed plan (`SkillProposal.plan`) has that revision. On the organizer, it is the parent plan updated; on a friend's phone, it is built from the terms.
   - Lane E applies a link only over the revision just before, so it applies once and never over a newer revision.
   - A plan whose next revision would not fit in a round (revision 15 and up) takes no further place, and nothing is sent.
   - The revision a proposal names is part of what it is. The same terms at another revision are a new proposal and need a fresh decision from the owner. A friend's agreed plan stores it, so a relaunch still tells a retry from a new proposal.
11. **The rule survives a relaunch.**
   - What a request on a plan is (a first place, or a change with the roster and revision it changes) is saved in the Pick a place ledger before anything is sent or answered, on both sides. It is kept for the request's whole life, 60 days.
   - A record that is missing or cannot be read is treated as a change, the stricter rule. On a friend's phone, no proposal can match it, so nothing new is shown.

Without a `Plan` input, for example after Find a time or from New, nothing changes: the most-friends rule of ADR 0230 still applies.

## Consequences

- **No place change can shrink a plan.** Lane E's `parent(updatedBy:)` still narrows the parent to a link's roster. That still happens for a plan's first place, as lane F's `aShortenedRealPlaceRosterMustCarryIntoTheNextChain` expects, but never for a change of place.
- **The revision must survive the parent update.** Lanes A and E apply the produced place with `Plan.updating`. Rebuilding the plan with `Plan(...)` would reset its revision to 0 (`docs/requests/P15-D.md`, item 13).
- **One outdated phone blocks a change.** A plan with a friend whose phone lacks Pick a place cannot change its place until that phone is updated.

## Sources

- ADR 0022 and the Orchestrator's instruction for lane D, 2026-10-02
- Lane F's `ChainingIntegrationTests.aShortenedRealPlaceRosterMustCarryIntoTheNextChain`, for the first place
- Tests: `Packages/Skills/PickAPlace/Tests/PickAPlaceTests/PlanChangeTests.swift`
