# ADR 0240: Chain links, per-link consent, and time-triggered chains

- Status: Proposed
- Date: 2026-10-01
- Owner: P15-E (Chaining and audit)

## Context

ADR 0012 sets the rules for chaining: suggestions come from `SkillRegistry.chainSuggestions` and are hidden when the group cannot run them; a chained skill that adds a topic or permission over "what the owner already granted for the plan" runs Consent again; nothing that adds either runs without a tap; an after-plan-ends skill starts when `Plan.endsAt` passes, only with an opt-in at Confirm, recorded in `ChainLink.optedInAt`; every envelope of a link carries `chainedFrom`; and a peer's `chainedFrom` never starts anything (ARCHITECTURE rule 8).

Core v2 leaves four things open:

1. What "already granted for the plan" means.
2. Where an after-plan-ends opt-in lives between Confirm and the plan's end. `ChainLink` sits on the chained `Interaction`, which does not exist until the skill starts.
3. How "every envelope of the link carries `chainedFrom`" is enforced when the skills that send belong to other lanes.
4. What the receiving phone does with a peer's `chainedFrom`, given that `Interaction` has no field for it and a `ChainLink` records the owner's own opt-in.

## Decision

1. **Granted means what the owner said yes to in this plan.** `ChainPlanner.grantedExposure` is the union of `SkillDescriptor.exposure` (topics used and permissions) over every interaction in the plan's chain whose history reached confirmed, planned, or done. A link the owner declined, or one still waiting for a yes, grants nothing. A row's `adds` is `next.exposure.adding(over: granted)`.
   - Down for… then Pick a place adds Diet and Location When In Use, so it needs a fresh Consent. A second "Somewhere else?" after a finished Pick a place adds nothing and starts on the tap alone.
   - This uses declared exposure, not what actually left. A topic a skill declares but never sent still counts as granted. The alternative, granting only topics in the egress log, would ask again for topics the owner already approved in principle, and permissions never appear in the egress log at all.
2. **"Keep it going" rows are conservative.** `ChainPlanner.suggestions` returns rows only for a planned interaction, and hides a row when:
   - anyone else in the plan lacks the skill, runs another major version, or has no card on this phone;
   - the plan produced nothing the skill accepts;
   - a link of the same skill from this plan is still working (before planned), so "Somewhere else?" returns once the last one settles;
   - for an after-plan-ends skill, the plan has no end time.

   The people a link goes to are the plan's attendees (ADR 0012 decision 8) minus this phone.
3. **A tap and a matching consent, checked again at the tap.** `begin` (at Confirm) and `optIn` (after the plan ends) take an `OwnerTap` and, when the row adds anything, a `LinkConsent` for the same parent and skill covering at least what the row adds. Both recompute the row from the current interactions, settings, and cards first, so a card, a switch, or a Never topic that changed after the row was drawn refuses the start (`notOffered`), and a row that now adds more than was approved asks again (`consentRequired`).
4. **An opt-in is a waiting interaction.** `optIn` returns a drafting initiator interaction with `ChainLink(trigger: .afterPlanEnds, optedInAt: tap)`. The app saves it in its `InteractionStore`, so it survives a restart with no new storage. Switching it off removes it (`optOut`): nothing ran and nothing left the phone. Lane A shows it as the plan's "Photos after" chip rather than a row under In progress.
5. **The schedule checks everything again when the plan ends.** `PlanEndSchedule.check` starts a waiting link only if:
   - its parent is still planned or done, and the stored link names the parent's conversation;
   - the parent was already planned when the owner tapped (so the opt-in was made at Confirm);
   - the skill is still in the build, switched on, not blocked by a Never topic, and at the version the owner approved;
   - everyone in the plan still runs it.

   Otherwise it returns a cancel with the event that ends the link in history (withdrawn, unsupported, or blocked by privacy), never a silent wait. Only initiator interactions in drafting can wait, so an invitee interaction, which starts negotiating, can never be started by the schedule. `PlanEndScheduler` runs the check while the app is open, napping until the next end (capped at a minute by default) and handing each link over once. `nextEnd(after:)` lets the app schedule a local notification at the plan's end with `UNCalendarNotificationTrigger`, so the check also runs when the owner opens it.
6. **`chainedFrom` is enforced on the way out.** `ChainedFromPolicy` wraps the app's `PolicyEngine`. For a conversation whose stored interaction has a `ChainLink`, an envelope whose `chainedFrom` is missing or names another conversation is denied (`chain.chained_from_mismatch`) before the wrapped policy or any consent sheet sees it. A store failure denies (`chain.store_unavailable`). Other conversations pass through unchanged, so privacy topics still decide egress. The app must save a link's interaction before calling its service's `start`.
7. **A peer's `chainedFrom` only groups.** `IncomingChain.timelineParent` accepts a hint only if it names a conversation on this phone that became a plan (planned or done) and the sender is in that plan. Accepted hints group the invitee interaction on the plan's timeline as a friend's request (`PlanTimeline.Entry.Origin.friend`). A hint is never turned into a `ChainLink`, never enters the schedule, and the package has no path from an incoming envelope to `begin`, `optIn`, or a permission.

## Consequences

- Lane A wires: the "Keep it going" list from `suggestions`; the link consent sheet from `ChainSuggestion.adds`; `begin`/`optIn` on the tap; `ChainedFromPolicy` around its policy; `PlanEndScheduler` with the cancel events applied; a notification at `nextEnd`; and the friend hint map (see `docs/requests/P15-E.md`).
- Opt-in and link consent are approvals of a skill's declared exposure, separate from the per-send consent sheets the policy still raises for Ask me topics.
- The opt-in survives a restart, but `PlanEndScheduler` runs only while the app is open. A plan that ends while Starling is closed starts its link the next time the owner opens it, which the notification prompts.

## Sources

- ADR 0011 (lifecycle), ADR 0012 (artifacts and chaining), ADR 0013 (permissions just in time), ADR 0014 (privacy topics)
- Phase 1.5 prompt, section 4; mockups "It's a plan" and "Plan detail"
- `UNCalendarNotificationTrigger`: https://developer.apple.com/documentation/usernotifications/uncalendarnotificationtrigger
- `Packages/StarlingChaining/Sources/StarlingChaining/KeepItGoing.swift`, `StartingALink.swift`, `PlanEndSchedule.swift`, `ChainedFromPolicy.swift`, `IncomingChain.swift`, and their tests
