# ADR 0162: Build match and decide schemas at runtime, and enforce limits in them

- Status: Proposed
- Date: 2026-09-30
- Owner: C2. Agent quality

## Context

Static `@Generable` schemas cannot know what a call offers:

- **decide.** `MoveOutput` always had time, activity, and budget fields. A time-only negotiation (the bench's `parent-student`) answered with "activity option 2", which validation rejected, so every such call failed. The model also accepted proposals that broke hard limits (6 violations in 21 calls on the Xcode 27 baseline), which the Phase 0 bench had already found prompt wording cannot fix.
- **match.** `MatchOutput` was a list of (want, offer, same) pairs. The only way to say "no match" was an empty list, and the model never produced one. Red-team issue #9: `match(wanted: [food], offered: [movie])` matched in 24 of 24 greedy trials.

`DynamicGenerationSchema` builds a schema at runtime. Checked against the Xcode 27.0 SDK interface and Apple's documentation JSON: it and `GenerationSchema(root:dependencies:)` are available from iOS and macOS 26.0, with string choices (`anyOf:`), arrays, typed values with guides (`type:guides:`, including `.range` for `Int`), optional properties, and named references (`referenceTo:`) resolved through `dependencies`. `LanguageModelSession.respond(to:schema:includeSchemaInPrompt:options:)` returns `GeneratedContent`, read with `value(_:forProperty:)`. Because it is 26.0 API, this runs on the macOS 26.7 host and on every iOS 27 device.

## Decision

1. **decide: `DecisionSchema`**, built per call.
   - A field only for each issue the proposal is about. Option numbers are `Int` with `.range(1...n)`, where `n` is the number of options listed.
   - Options listed in the prompt are only those that meet the owner's hard limits (and are not avoided keywords). The budget field is bounded to the owner's range, rounded inward.
   - `accept` is not offered when the proposal breaks a limit. A counter must set every broken issue, because it keeps the proposal's value for anything it leaves out.
   - When only one move remains, code returns it without a model call: `reject` when no counter can fix a broken issue, `accept` when nothing is broken and the owner has no soft preference on any issue in play (every compliant term is as good as another). These report 0 tokens.
   - The Phase 0 `brokenItems` field is removed. Code knows the broken items. Also, an array whose items are a one-choice `anyOf` (a time-only proposal) made the macOS 26.7 model service fail with `ModelManagerError 1032`; other shapes worked.
2. **match: `MatchSchema`**, built per call. One property per want, whose value is `none` or one of this call's offers, then a same-meaning Bool. The offer choice is defined once and referenced, so a 6-by-10 call stays near 1,500 tokens instead of about 3,000. Property names contain a colon (`want:<keyword>`, `same:<keyword>`), which no `Keyword` can, so no keyword, the owner's or a peer's, can make two properties share a name.
3. Output is still validated after generation (`OutputMapping`), not trusted because the schema was constrained.

## Consequences

Measured with the real model on this Mac (see `Packages/StarlingAgent/Reports/phase-1-quality.md`):

- **decide:** errors 3 to 0, limit violations 6 to 0, worst call within the ADR 0002 budget of 2048 tokens. Convergence changed: `down-2p` used to "agree" by accepting terms that broke a limit and now ends in reject after 6 rounds, because no listed option fits both sides. `parent-student` went from failing every run to agreeing every run.
- **match:** negative controls with a false match 18/18 to 4/18, and food/movie alone now returns no match. Satisfiable wants found stayed at 17/17 (the old matcher found them all only because it matched everything).
- **Issue #9 is only partly fixed.** With a second offer (lane I's benign "quiet evening", or an injection phrase), food still matches movie or the injected label. Four other match designs were measured and rejected: a model-labeled kind gate (false matches 3/18, but wants found fell to 6/17, 3,015 tokens), per-offer choices (4/18, but food/movie in every two-offer case, 1,955 tokens), pair verdicts (4/18, 5,248 tokens), and dropping the same-meaning Bool (5/18). These comparisons were measured before the property names gained their colon prefixes; the chosen design went from 5/18 to 4/18 with the new names. The remaining defense is structural: match results only propose, and Down notifies only after both sides accept (ARCHITECTURE section 7).
- Offering only compliant options means a negotiation can only converge on an option one side listed. When the sides' windows overlap only partially, no listed option fits both (`down-2p`). Offering intersections of the two sides' windows is a negotiation design question for lane F, not a model fix.
- Match latency and tokens rose (worst call 566 to 1,519 tokens), still well within budget.

## Sources

- `DynamicGenerationSchema`: https://developer.apple.com/documentation/foundationmodels/dynamicgenerationschema
- `GenerationSchema.init(root:dependencies:)`: https://developer.apple.com/documentation/foundationmodels/generationschema/init(root:dependencies:)
- Xcode 27.0 SDK: `FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`, build 27A266a
- TN3193, on schema token cost: https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
- ARCHITECTURE.md rule 6 and section 7
- Red-team issue #9: https://github.com/oliverrowebardeen/starling-ios/issues/9
