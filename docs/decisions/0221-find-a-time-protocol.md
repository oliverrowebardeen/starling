# ADR 0221: Find a time is one private query per friend, then a plan

- Status: Proposed
- Date: 2026-10-01
- Owner: P15-C, Find a time

## Context

Find a time agrees on when, with friends whose owners may or may not keep a calendar (brief 2.3). Its descriptor uses the private query building block: "an agent answers a question from its owner's data without exposing the data" (brief 2.7). Core's `Query` is "which of these candidates are acceptable to you?", and an `Answer` reveals only the acceptable subset.

Constraints:

- **Small domains.** Brief 3.9: a week of half-hours is about 336 items, so a peer who can ask about every slot learns the owner's whole availability.
- **No private set intersection yet.** Core ships only `InsecurePSIStub`, which reveals the initiator's set. Down for… pays for PSI with a consent sheet on every run while the stub is in use (ADR 0120); scheduling across a week would do the same.
- **The mockup's promise.** ADR 0013's sheet says "Priya sees: only times you're both free". Without PSI, one side must name times first, so that line cannot hold for both roles.
- **Silence and passes.** "If you pass, they just won't see it" (ADR 0017).
- **Lifecycle.** Events must be ones `InteractionState.applying(_:)` accepts (ADR 0011), and delivery is best effort (ARCHITECTURE rule 5).

## Decision

### The exchange

1. **Starter.** The owner's range and daily window (from the chips) become hourly candidates in the owner's time zone. Several hard `within` windows are intersected, since each is a limit, and every candidate is checked with `ConstraintSet.violations` (ARCHITECTURE rule 6). The starter's availability (ADR 0220) filters them; without a calendar, the starter's own owner picks which work, in one `SkillQuestion`. At most 16 of the free candidates are offered, spread across the range.
2. **Query.** One `query(time, slots)` to each friend, with the skill's `SkillRef`, mode Invite, and any `chainedFrom`. Find a time offers only Invite (`sendModes [.invite]`, ADR 0020): asking quietly needs mutual reveal. An envelope in any other mode is ignored, so a quiet ask never becomes a card.
3. **Friend.** The friend's agent checks the query and drops any candidate that breaks its owner's standing limits ("no plans before 10"), then answers from its calendar or stated intent without asking anyone. If neither knows, its owner gets one `SkillQuestion` listing the offered times ("Priya's agent asked when you're free"). The answer lists the offered times that work.
   - The answer is a yes or no to the starter's own candidates, so it is sent with the query in `OutboundContext.answering`, and the policy allows it without a sheet to an on-device agent whatever the time topic is set to (ADR 0019, decision 4).
   - Calendar details are read on the phone even when that topic is Never, the default: Never keeps them from leaving, not from use (ADR 0019, decision 3). They are in `topicsUsed`, never in `topicsRequired`.
   - One query of at most 16 times per conversation keeps answers within `ProtocolLimits.maxCandidatesAnsweredPerIssue`.
4. **Choose.** When every friend has answered, or after 30 minutes, the starter picks the time the most friends can make, earliest first. Friends not in it get "no plan".
5. **Propose.** One `propose` with the time, the activity if any, and, for three or more people, the roster under `people`. A pair sends no roster, which keeps the people topic, and its default Ask me sheet, off two-person requests. The starter's own card goes up only after every proposal send has cleared policy and consent.
6. **Confirm.** Each friend's owner taps "That works", which sends `accept` naming the proposal and its exact terms. That acceptance repeats only what the starter sent, so it carries the proposal in `OutboundContext.accepting` and goes like a yes under any topic choice (ADR 0019, amendment 10). The starter's confirmation repeats its own terms and stays under the topics. When the starter's owner and every friend in the plan have accepted, the starter sends its own `accept` of the same terms to each friend as the confirmation.
   - The starter's plan exists only once every confirmation has left the phone (cleared policy and consent and reached the link); until then it is confirming, and a restart finishes the sends through Outbox.
   - A friend's plan exists only once its own acceptance has left and a matching confirmation has arrived. A confirmation that comes earlier, for example while the acceptance waits on a consent sheet, is held until then.
   - Both sides then report `everyoneConfirmed` and produce a `TimeSlot` and a `Plan`. The coordinator applies `planEnded` (ADR 0011, amendment 15).
7. **A pass in a group.** If a friend passes on the proposal, the others get a new revision with the same time and the smaller roster, and everyone confirms again. An "I'm in" on an older card is refused as stale.

### What each side reveals

8. **The friend reveals only times both are free.** Its answer is a subset of what the starter offered.
9. **The starter reveals the times it offers.** With a calendar, the gaps between offered times show busy time inside the range, but never why. The sheet's third line therefore differs by role: "Only a few times you're free" when starting, "Only times you're both free" when answering (`FindATimeCopy.PermissionSheet`). Changing ADR 0013's wording is requested in `docs/requests/P15-C.md`.
10. **Every no looks the same.** No free time, a policy refusal (a Never setting), a pass, and a declined consent sheet all send the same `reject(noOverlap)`, with no issue values, both when answering and when agreeing. Core v2.1 numbers an envelope only once it is cleared, so a refused send leaves no gap in sequence numbers either. Tests compare the friend's whole envelopes across these cases (ADR 0019, decision 5).
    - **Timing.** The noes that need no owner (no free time, a refusal) go out on the same path as soon as availability is read. The noes that come from the owner (a pass, a declined sheet) go out when the owner acts. A starter can still tell from timing whether a friend's agent answered alone, which is what a calendar does; that is not a privacy setting, and hiding it would mean delaying every calendar answer.

### Every peer value is checked

11. **A query** must ask about `time` with 1 to 16 distinct slots, each 5 minutes to 8 hours long, ending after now and starting within 15 days. Anything else is dropped before an interaction, a question, or a calendar read exists. A friend may have at most 4 open requests here, and all friends together 32.
12. **An answer** must come from a friend who was asked, and list only offered times. One extra time voids the whole answer, so a friend cannot steer the plan to a time the starter never offered.
13. **A proposal** must come from the friend who asked, name one time this phone said works, carry at most one activity, and, if it has a roster, include both phones. Rounds only rise. One that breaks the owner's standing limits (an activity they avoid) is passed on by the agent, like any no.
14. **A confirmation** must name a proposal envelope this phone accepted and repeat its terms exactly.
15. A late query or proposal for a conversation that ended here gets "no plan" again, at most `maxAttempts` times, and never a new card.

### Delivery, deadlines, and consent

16. Each step that expects a reply is resent every 5 seconds, up to 6 times, and again when the friend's link comes back, but never while the previous send of the same step is still waiting (on a consent sheet, say), so a retry never opens a second sheet. Retries are recognized by content and answered from what was already said.
17. Deadlines: the starter waits 30 minutes for answers and 1 hour for "That works", both capped by the request's expiry; a friend keeps a request for 6 hours. Expiry tells the others "no plan".
18. **Consent and refusals.** The coordinator applies `.started` when the owner sends, before `start` (ADR 0011, amendment 13); the service never reports it. Every send names its interaction in `OutboundContext.interaction` (Core v2.1), so the sheet suspends the right one. The app's `ConsentProvider` applies `consentNeeded`, `consentGiven`, and, on a decline, the owner's pass; the service adds no event for a decline, ends the conversation, and friends already asked hear "no plan". A send the policy denies ends the interaction as blocked by privacy, at any live step but planned, where the plan stands. Either result counts only for a send made for the current step; one that arrives after its step was superseded, such as the acceptance of proposal 1 after proposal 2 replaced it, is dropped (ADR 0011, amendment 14).
19. **Withdrawal stops sends in flight.** Each conversation's sends run in tasks that are cancelled when it ends, is withdrawn, or the app shuts down, so a send waiting on a consent sheet never leaves afterwards. A friend never asked is never told anything, not even "no plan".
20. The service applies every event to its own copy of the `Interaction` first and emits only what the lifecycle accepts, so the coordinator never has to drop one of its events.

## Consequences

- A calendar owner and a no-calendar owner complete the same exchange; the only difference is whether their agent answers alone or asks them one question.
- Nothing needs consent under the default topics (time and activity Share) with on-device friends, and a two-person plan never touches the people topic.
- **Remaining leak.** A starter shows friends up to 16 of its free times. A dishonest friend who keeps starting requests learns 16 of the owner's answers per request; the per-friend cap of 4 open requests bounds the rate, not the total. A private PSI (Nightjar) would remove this; recorded for the threat model.
- Picking "the most friends" can leave a friend out of a group plan. The friend left out sees "no plan", like a pass.
- Withdrawing after a plan is made ends it on this phone only; friends are not told. Cancelling a confirmed plan is out of scope for Phase 1.5.

## Sources

- Brief sections 2.3, 2.7, and 3.9, `docs/BRIEF.md`
- ARCHITECTURE.md section 2 (rules 5, 7, and 8)
- ADRs 0011, 0012, 0013, 0017, and 0120
- `Packages/StarlingCore/Sources/StarlingCore/Messages.swift` (`Query`, `Answer`, `Rejection`) and `Interaction.swift`
