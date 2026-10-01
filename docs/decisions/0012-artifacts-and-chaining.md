# ADR 0012: Skills chain through typed artifacts, with consent per link

- Status: Accepted
- Date: 2026-09-30
- Owner: Orchestrator

## Context

Phase 1.5 section 4: skills connect through typed artifacts.

| Artifact | Produced by | Accepted by |
|---|---|---|
| Plan | Down for…, Find a time | Pick a place, Swap photos, Add to Calendar, handoffs |
| TimeSlot | Find a time | Down for…, Pick a place |
| PlaceChoice | Pick a place | Plan (updates it), handoffs |
| Attendees | any skill that confirms a group | Swap photos, Message the group |

At Confirm, "Keep it going" suggests chains (mockup "It's a plan · chained skills"). A skill may start itself relative to a plan (Swap photos when the plan ends), with explicit opt-in. A chained skill that touches a new privacy topic or permission runs Consent again. Every link appears on the plan's timeline and in its egress log. A chain the peers cannot run is hidden.

Rule 7 of ARCHITECTURE.md says no free text crosses the wire. Agreeing on a venue needs its name.

## Decision

1. **Artifacts in StarlingCore**: `Plan`, `TimeSlot` (existing), `PlaceChoice`, and `Attendees`, wrapped by `Artifact` with an `ArtifactKind`.
   - A `Plan` needs an activity or a time. It is built on each phone from the agreed terms and stays there. `Plan.updating(place:)` applies a `PlaceChoice`.
   - `Attendees` lists 2 to 16 distinct peers, the owner included.
2. **Venues on the wire.** `IssueValue.places([PlaceChoice])` (1 to 8) lets Pick a place exchange candidates and the agreed venue.
   - A `PlaceChoice` holds a `PlaceName` (1 to 64 characters, no control characters or line breaks, validated on decode), an optional coordinate to five decimals, and Apple Maps' item identifier.
   - A venue name is the one bounded display string a peer may send. It is shown to people and never treated as an instruction.
   - Until lane D designs how the model sees places, the prompt renderer shows "N place options", never venue names. A 64-character name allows spaces and punctuation, so it could carry an instruction-like phrase.
3. **What can chain.** A skill can follow another when it accepts at least one kind the other produces (`SkillDescriptor.canFollow`).
   - Suggestions come from `SkillRegistry.chainSuggestions`, which drops anything not available locally or not supported by every peer's card.
   - A suggestion the group cannot run is hidden, not shown and then failed.
4. **Consent per link.** `SkillExposure.adding(over:)` gives the topics and permissions a chained skill adds over what the owner already granted for the plan.
   - Non-empty means Consent runs again before the link starts.
   - Nothing that adds a topic or permission runs without a tap.
5. **Time-triggered chains.** `ChainTrigger.afterPlanEnds` lets a skill start when `Plan.endsAt` passes, but only if the owner opted in at Confirm. The opt-in is recorded in the `ChainLink`, with `optedInAt`.
6. **A peer cannot start a chain.** `Envelope.chainedFrom` names the conversation a chained skill continues, so the receiver can group it on the plan's timeline. It is a hint only.
   - An incoming envelope with `chainedFrom` creates an invitee interaction like any other request: it shows under Needs you if the owner must act.
   - It never starts a skill, asks for a permission, or skips Consent on the receiving phone.
   - Lane F's red team tests this.
7. **Timeline and audit.** `Collection<Interaction>.chain(from:)` returns the root and every link in start order, for "How this came together". Each link's egress log feeds "What left your phone".

## Consequences

- The chaining lane builds suggestions, triggers, and the timeline from Core types, with no skill-specific code.
- A venue name is a new kind of peer-supplied text. Rule 7's structural defense holds: it is typed, bounded, and validated, never an instruction. But it widens the injection surface, so lane D and lane F must cover it before places reach a prompt.

## Sources

- Phase 1.5 prompt, section 4; mockups "It's a plan · chained skills" and "Plan detail · skill chain + what left your phone"
- `Packages/StarlingCore/Sources/StarlingCore/Artifacts.swift`, `SkillRegistry.swift`, and `Interaction.swift`
