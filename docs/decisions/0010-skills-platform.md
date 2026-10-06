# ADR 0010: Starling is a platform of skills

- Status: Accepted (decision 2, the intent schema as data rather than `@Generable`, approved by the owner on 2026-09-30)
- Date: 2026-09-30
- Owner: Orchestrator

## Context

The Phase 1 device review found the whole app built around Down. The Phase 1.5 prompt (the owner, 2026-09-30) makes features into **skills**: Down for…, Find a time, Pick a place, and Swap photos now; Gift pool, Vouch, and Keep in touch later. A skill provides only what is unique to it: an id and version, an intent schema the model fills from free text, its building block, the privacy topics it touches and requires, the system permissions it may need, the artifacts it accepts and produces, and its proposal wording.

The prompt asks for a `StarlingSkill` protocol with an `@Generable` intent schema. Two constraints shape that:

- `StarlingCore` is Foundation-only, and ADR 0009 keeps `FoundationModels` out of it so every lane tests against fakes and one package owns every prompt.
- A2A makes `AgentCard.skills` required (`repeated AgentSkill skills = 12 [(google.api.field_behavior) = REQUIRED]`), but `AgentSkill` has no version field. The required fields are `id`, `name`, `description`, and `tags`; the version on an A2A card is the agent's own.

## Decision

1. **A skill is three parts, all in StarlingKit:**
   - `SkillDescriptor` (StarlingCore, data only): `SkillRef` (id and version), `SkillWording`, `BuildingBlock`, topics used and required, `SystemPermission`s, accepted and produced `ArtifactKind`s, an `IntentSchema`, and a `ChainTrigger`.
   - `SkillService` (StarlingCore protocol): the runtime over the app's single Outbox and Inbox. It generalizes Phase 1's `DownService`.
   - `SkillModel` (StarlingCore protocol, implemented in StarlingAgent): routing, intent parsing, and proposal sentences (ADR 0016).
2. **The intent schema is data, not an `@Generable` type.** `IntentSchema` lists issue slots (required or not, with a hint for the prompt). StarlingAgent builds the guided-generation schema from it at runtime, the pattern ADR 0162 already ships for match and decide. This keeps ADR 0009's boundary: the skill packages never import `FoundationModels`, and every prompt stays in one package.
3. **Wire names and versions.** `SkillID` has the `IssueKey` format (`down_for`, `find_a_time`, `pick_a_place`, `swap_photos`). `SkillVersion` is `major.minor`, and two agents can run a skill together when the majors match. This is Starling's own extension. When the A2A bridge lands (Phase 3), the version travels in the skill's `tags` or `id`.
4. **Agent cards advertise skills.** `AgentCard.skills: [SkillRef]`, at most 32 and no duplicates. A Phase 1 card without the key decodes with no skills. `AgentCard.support(for:)` answers supported, missing, or incompatible. The app turns missing into "Maya's Starling doesn't do this yet" and hides chain suggestions the group cannot run. `Capability` stays for protocol features such as `psi`.
5. **Envelopes carry the skill.** Envelope version 1 adds `skill: SkillRef?` and `chainedFrom: ConversationID?` (ADR 0012). Version 0 frames from Phase 1 builds still decode, without either field. Phase 1 builds reject version 1, so both test phones need the Phase 1.5 build.
6. **Registry and flags.**
   - `SkillRegistry` holds the descriptors in display order. `SkillFlags.phase1_5` switches on Down for…, Find a time, and Pick a place. Swap photos ships flagged off, far enough only to prove the time-triggered chain hook.
   - `SkillAvailability` says why a skill cannot run: not in this build, turned off by the owner, or blocked by privacy.
   - The card advertises skills that are in the build and switched on. A skill blocked only by a Never topic stays advertised and declines at request time, so the card never reveals the owner's privacy choices.
7. **One package per skill**, under `Packages/Skills/<Name>/`, each owned by one lane (ADR 0006).

## Consequences

- A new skill needs only a descriptor, a service, and its model hints. The shell, consent, lifecycle, chaining, and audit are shared.
- Skill packages are testable with `ScriptedSkillModel`, `ScriptedSkillService`, and `SampleSkills` from `StarlingFakes`.
- The intent schema cannot use `@Generable`'s compile-time features (`@Guide` on Swift properties). Slot hints and runtime schema construction replace them. ADR 0162 measured this pattern on the real model.
- Phase 1's `DownService`, `DownIntent`, and `DownEvent` stay in Core until lane B moves Down into its skill package, then they go.

## Sources

- A2A specification, AgentCard and AgentSkill: https://a2a-protocol.org/latest/specification/#441-agentcard
- A2A v1.0.1 proto (`skills` REQUIRED; AgentSkill fields): https://github.com/a2aproject/A2A/blob/v1.0.1/specification/a2a.proto
- Guided generation with `@Generable`: https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation
- ADR 0009 (task-level model interface), ADR 0162 (runtime schemas)
