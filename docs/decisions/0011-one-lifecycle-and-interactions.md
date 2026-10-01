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

## Consequences

- Home, the proposal card, It's a plan, and the plan timeline render any skill, including future ones, from `Interaction` and `SkillDescriptor` alone.
- Silence stays the default: nobody up, declined, and expired end in history without notifying anyone (brief 2.6).
- Down's Phase 1 `DownEvent` maps onto these events when lane B moves Down into its skill package.

## Sources

- Phase 1.5 prompt, sections 3 and 7 (Oliver, 2026-09-30); mockups "Home · inbox across skills" and "Plan detail · skill chain + what left your phone"
- `Packages/StarlingCore/Sources/StarlingCore/Interaction.swift` and its tests
