# ADR 0011: One lifecycle for every skill, recorded as Interactions

- Status: Accepted
- Date: 2026-09-30
- Owner: Orchestrator

## Context

Phase 1.5 section 3: every skill goes Compose (intent and audience), Consent (what leaves the phone), Negotiate (status motion), Propose (one card), Confirm (both humans), Hand off (Calendar, Messages, Maps, Siri), and Remember (history and audit). Each step is a shared component; skills plug in and never build their own screens for these steps. Home groups work as Needs you, In progress, and Coming up (mockup "Home · inbox across skills").

## Decision

1. **One state machine** (`InteractionState`, StarlingCore):
   - The states: drafting, awaiting consent, negotiating, awaiting the owner, proposed, confirmed, planned, and done.
   - `ended(reason)`, with reason one of: declined, nobody up, expired, withdrawn, failed, unsupported, or blocked by privacy.
   - "Awaiting the owner" covers the agent asking its own owner one question: the "Just ask me instead" fallback, or an invitee reviewing a request such as "Priya's agent asked when you're free next week".
2. **Each state maps to a lifecycle step and a Home section:**

   | Home section | States |
   |---|---|
   | Needs you | awaiting consent, awaiting the owner, proposed |
   | In progress | drafting, negotiating, confirmed |
   | Coming up | planned |
   | History | done, ended |
3. **Transitions are a pure function**, `InteractionState.applying(_:)`, over `InteractionEvent`s that skill services report. Final states accept nothing, so a late or replayed event cannot revive an interaction. An invalid event throws `InvalidTransition` and leaves the record unchanged. Withdrawn, expired, and failed end any live state.
4. **`Interaction`** is one use of one skill on this phone. It holds:
   - the shared `ConversationID` (every envelope of the interaction carries it), the `SkillRef`, the role (initiator or invitee), and the participants;
   - the state history, which is "How this came together";
   - an optional `ChainLink` (ADR 0012) and the artifacts it produced;
   - an egress log of `EgressRecord`s, which is "What left your phone".

   An initiator starts in drafting. An invitee starts negotiating, because its agent is already handling the request.
5. **The egress log uses the consent sheet's items.** `EgressRecord` stores the same `DisclosedItem`s the policy computes for the consent sheet, recorded by an `OutboxObserver` after each successful send. The audit cannot disagree with what the owner approved.
6. **`InteractionStore`** is the persistence protocol. The shell lane chooses the storage; `StarlingFakes.InMemoryInteractionStore` is the double.
7. **One coordinator.** The app runs one lifecycle coordinator. It consumes every `SkillService`'s `SkillEvent`s, applies them to the store, and drives the shared screens. Skills never write interactions themselves.

### Amendments after the review of PR #45 (2026-09-30)

8. **Consent suspends the step it interrupts.** Any send can need consent, including the acceptance an invitee's "I'm in" sends. `awaitingConsent(resume:)` records the interrupted step (negotiating, awaiting the owner, proposed, or confirmed).
   - Granting consent resumes that step.
   - Passing ends declined.
   - The others giving up meanwhile ends nobody up.
9. **Answers bind to a proposal revision.** Revisions only increase.
   - `SkillProposal`, `SkillQuestion`, `OwnerAnswer.accept(proposal:)`, `.reply(question:_:)`, and the `proposalReady`, `ownerAccepted`, and `everyoneConfirmed` events carry one.
   - `Interaction` throws `StaleProposal` for an acceptance or confirmation of anything but the current revision, so a tap on an older card never accepts newer terms.
10. **Content travels with its event** (review 3).
    - `ownerNeeded` carries the `SkillQuestion`, and `proposalReady` the `SkillProposal`, so content, revision, and state change in one validated step. The current revision is read from the stored proposal.
    - `ownerAnswered(question:)` names the question it answers.
    - A restarted app rebuilds every card from the store, and `SkillService.restore(_:)` hands each skill its live interactions.
11. **Consent requests carry IDs** (reviews 2 and 3). `consentNeeded` and `consentGiven` name a request.
    - The interaction resumes only when its last open request is approved.
    - Question revisions and consent IDs each keep a high-water mark that only rises, persisted with the interaction, so a completed one can never be reopened or replayed.
12. **Consent requests are scoped to their interaction.** `Disclosure` carries the conversation and skill, and both are part of its equality. A remembered approval, or a queued request settled with it, never crosses into another interaction. A retry inside one conversation still reuses the approval.

## Consequences

- Home, the proposal card, It's a plan, and the plan timeline render any skill, including future ones, from `Interaction` and `SkillDescriptor` alone.
- Silence stays the default: nobody up, declined, and expired end in history without notifying anyone (brief 2.6).
- Down's Phase 1 `DownEvent` maps onto these events when lane B moves Down into its skill package.

## Sources

- Phase 1.5 prompt, sections 3 and 7 (Oliver, 2026-09-30); mockups "Home · inbox across skills" and "Plan detail · skill chain + what left your phone"
- `Packages/StarlingCore/Sources/StarlingCore/Interaction.swift` and its tests
