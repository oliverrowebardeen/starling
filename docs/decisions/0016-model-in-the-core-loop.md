# ADR 0016: The model works in the core loop

- Status: Accepted
- Date: 2026-09-30
- Owner: Orchestrator

## Context

The device review found the on-device model doing almost nothing in the core loop: it only turned rules text into rules, which a form does better. Brief 2.4 says a feature qualifies only if the model does real work. Phase 1.5 section 8 gives it four jobs:

- **Routing:** free text in New picks a skill.
- **Intent parsing:** free text becomes editable chips. "boba tonight with whoever's free, nothing far" becomes Down for… · Boba · Tonight after 7 · Nearby · Expires in 3 hrs.
- **Fuzzy matching:** "food" matches "boba run", and overlapping windows produce a proposed time.
- **Proposal writing:** "You, Maya and Jake are all down for boba. Boba Guys on Franklin at 8:30?"

Everything a peer sends stays untrusted. Typed schemas only; the deterministic policy decides egress; chaining must not let a peer's message trigger a new skill or permission.

Verified (2026-09-30):

- A `@Generable` enum is the documented way to constrain output to one of a fixed set of cases.
- iOS 27 adds `GenerationOptions.ToolCallingMode` (`.allowed`, `.disallowed`, `.required`), `DynamicProfile`, and a new on-device model. Apple says to retest prompts against it.
- Phase 1's quality measurements (lane C2, ADRs 0160 to 0162) ran on the macOS 26.7 model, not the iOS 27 one.

## Decision

1. **`SkillModel`** (StarlingCore protocol, implemented in StarlingAgent) holds the three new jobs. `AgentModel.match` keeps fuzzy matching.
   - `route(_:among:)` returns a `SkillID` or nil. StarlingAgent builds a runtime enum schema from the available skills' ids and summaries, so the model can only answer with a skill that can run now, or "none".
   - `intent(from:for:now:timeZone:)` returns a `ParsedIntent`: constraints, audience, expiry, and names the owner mentioned. The schema comes from the skill's `IntentSchema` (ADR 0010). Grounding against the owner's words (ADR 0161) applies to every slot.
   - `proposalText(_:)` writes one sentence from `ProposalFacts`: typed values plus the owner's own nicknames for friends. The text is shown only on this phone and never sent. Each skill ships a template fallback that produces the same sentence without the model.
2. **The model proposes; code and the owner decide** (ARCHITECTURE rules 4 and 6).
   - Routing and chips are suggestions the owner sees and can edit before anything is sent.
   - Hard limits are checked in code before and after every call.
   - No model output decides egress, starts a skill, or requests a permission.
3. **Peer input stays typed.**
   - The only peer data a prompt may contain is bounded typed values: keywords, time slots, amounts, counts.
   - Venue names stay out of prompts (ADRs 0012 and 0231).
   - A peer's message can never route the owner's text, choose a skill, or produce a proposal sentence that triggers an action.
4. **Measure on the iOS 27 model.** Routing accuracy, chip accuracy, and match quality are measured with labeled sets, as in ADR 0160, on an iOS 27 device. The macOS numbers are a baseline only, not a release gate. Token budgets follow ADR 0002: count with `tokenCount(for:)` at runtime.

## Consequences

- The model now earns its place in every request: routing and chips replace forms, and proposal sentences replace templates when the model is available.
- Without Apple Intelligence or with the model unavailable, New falls back to the skill tiles and chip editing, and proposals use templates. Every skill still works.
- Lane B owns the StarlingAgent work for routing, intents, and proposals in Phase 1.5, taking over from Phase 1's lane C2.

## Sources

- Guided generation: https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation
- `GenerationOptions.ToolCallingMode`: https://developer.apple.com/documentation/foundationmodels/generationoptions/toolcallingmode-swift.struct
- Foundation Models updates: https://developer.apple.com/documentation/updates/foundationmodels
- Brief 2.4 and 3.6; ADRs 0002, 0009, 0160 to 0162
