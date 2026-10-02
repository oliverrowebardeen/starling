# ADR 0212: SkillModel: routing, chips, and proposal sentences

- Status: Proposed
- Date: 2026-10-01; revised the same day for Core v2.1 (ADR 0020) and the review of PR #56
- Owner: P15-B. Down for... skill and the model

## Context

ADR 0016 gives the model three new jobs behind `SkillModel` (StarlingCore), implemented in StarlingAgent: route New's free text to a skill, read the chips for that skill, and write a proposal card's sentence. ADR 0010 decision 2 makes a skill's intent schema data (`IntentSchema`), turned into a guided-generation schema at runtime. ADR 0161's grounding applies to every slot. ADR 0012 keeps venue names out of prompts.

Verified against the Xcode 27.0 macOS SDK interface (`FoundationModels.swiftmodule`, 2026-10-01): `DynamicGenerationSchema` has `init(name:description:anyOf: [String])`, `init(arrayOf:minimumElements:maximumElements:)`, `init(type:guides:)`, and `GeneratedContent(json:)`; these are the 26.0 APIs ADR 0162 already uses, so they run on the macOS 26.7 host and every iOS 27 device.

## Decision

1. **`FoundationModelsAgent` conforms to `SkillModel`.** Each call runs in a fresh session with greedy sampling, like `AgentModel`'s jobs, and maps framework errors to `AgentModelError`.
2. **Routing is a runtime enum.** `RouteSchema` offers the ids of the skills that can run now (`SkillRegistry.available`), then `none`, so the model cannot name a skill that is switched off, blocked, or not in the build. The prompt describes each skill from its descriptor only: name, summary, what its building block does, and every slot hint. Nothing is written per skill, so a new skill routes from its descriptor.
3. **Chips come from a schema built from the skill's slots.** `IntentGenerationSchema` adds fields only for the skill's slots, in its order: wants and avoids for activity; day, hours, and part of day for time; whole dollars for budget; up to three words for any other slot (place, diet, photos); audience and names when the skill asks for an audience; and a mode (`none`, `quietly`, `invite`) when the skill offers more than one send mode. ADR 0161's lessons carry over: enums lead with `none`, and hours and budget use sentinels for "not stated".
4. **Code grounds every chip in the owner's words** (ADR 0161, extended):
   - time, activity, and budget go through `Grounding.check` and `OutputMapping.rules`, as in Phase 1;
   - every keyword chip (activity, avoid, place, and any other slot's words) is the owner's words as typed (device test, 2026-10-02): a phrase of the message, whole, in the owner's spelling. It is never paraphrased, title-cased, or cut off, and no word is in two chips. Code reads the message as phrases, runs of words between punctuation and words no activity is made of (articles, prepositions, times, people, prices, rule words, with "night" and "day" allowed to end one, as in "movie night"). It takes the first phrase each of the model's proposals touches: "Watch Movie" becomes "movie night", "trip" becomes "IKEA trip", and a stretch such as "dinner tonight with Maya" becomes "dinner". A phrase joined by "or" or "and" to the first is a chip too, a phrase that is only a friend's name is not, and a phrase right after "no" is something to avoid. A distance is a place chip in the owner's words ("nothing far"), and after "near" the place is what follows ("near campus" is "campus"). `OwnersWords` does this. Keywords stay lowercase on the wire (peers compare them), so the app shows each chip as the matching words of what the owner typed (`ChipFormatter.spelling(of:in:)`);
   - a day or a group word ("friends") is never an activity;
   - another slot's word survives only if the message uses it, with one rule: "nearby" stands for "far" or "near";
   - a name survives only if it appears in the message, is not a word for a group, an activity, or a place, and keeps the owner's spelling;
   - the audience is everyone or close friends only if the message says so; a named friend makes the audience the app's to resolve;
   - "everyone except Jake" or "everyone but Jake" becomes `everyoneExcept([])` with Jake among the names; the small model files Jake under avoids, so code moves an avoid in that pattern into the names, and "anything but sushi" stays an avoid;
   - a mode only if the message says quietly or invite, and only one the skill offers;
   - sharing is never set by a request: privacy topics are global (ADR 0014);
   - the request expires when its time window ends, or in three hours.
5. **Proposal sentences see typed facts only.** The prompt lists the owner's nicknames for friends and the activity keyword. The time and the place are placeholders, `{time}` and `{place}`: code puts in the time phrase it computed ("tonight at 8:30 PM") and the venue name afterwards, so the sentence cannot get the day or the hour wrong (review of PR #56, finding 7), and a peer-supplied name never reaches the model.
6. **Code checks every sentence and falls back to the template.** A sentence is kept only if it is one line within 200 characters, names every friend, says the activity, has each placeholder exactly when its fact is given, and has no time of its own: no digit, day, part of day, AM, or PM. With no activity, it must not say "down" (ADR 0017). Dashes become commas. Anything else throws, and the app shows the skill's template sentence (`ProposalTemplate` in Down for...).
7. **Measured the ADR 0160 way.** `StarlingAgentBench` holds a routing set (40 tuning, 20 held-out) and a Down for... chip set (20 tuning, 10 held-out), with scorers that run against `ScriptedSkillModel` in CI and the real model with `agent-bench --routing` or `--chips`, or `STARLING_MODEL_TESTS=1` on a device.

## Consequences

Measured on the macOS 26.7 model (`Packages/StarlingAgent/Reports/phase-1.5-skill-model.md`):

| Set | Result |
|---|---|
| Routing, tuning | 32 / 40, then 36 / 40 after decision 2's prompt |
| Routing, held-out | 19 / 20 |
| Requests routed to none | 0 on both sets |
| Chips all right, tuning | 12 / 20, then 16 / 20 after decision 4's rules |
| Chips all right, held-out | 6 / 10 |
| Worst call | 1,811 tokens (chips), within ADR 0002's 2,048 |

- Routing failures go the safe way: no request was routed to none, and two to three non-requests were routed to a skill, which shows chips the owner dismisses. Nothing is sent before the owner taps the start button.
- Core v2.1 round: the mode chip was right in 23 of 23 tuning and 12 of 12 held-out items; all chips right in 20 of 23 and 6 of 12. Audience stays the weakest chip ("who's up for" is not read as everyone; "close friends" sometimes is), and a group's name came back as an avoid on the held-out set.
- `SkillModel` cannot see the friends list and `ParsedIntent` has no field for friends left out or a group, so names carry both by convention (requested in `docs/requests/P15-B.md`).
- The sets are small and written by one author; two tuning labels were widened after the first run, which the report states. These are evidence, not population estimates.
- The iOS 27 model is new and may score differently. The device checklist (part A) runs the same sets on an iPhone and asks for New to lead with tiles if routing is under 80% there.
- The word lists are English only, like ADR 0161's.
- Device-test round (2026-10-02, `Packages/StarlingAgent/Reports/phase-1.5-skill-model.md`): with the owner's-words rule, scored exactly and with an own-words check, chips all right went from 16 / 28 to 26 / 28 on tuning and from 5 / 17 to 12 / 17 on held-out. Own words is 28 / 28 and 17 / 17, and the worst call is 2,046 tokens. A chip can only be as good as the phrase the model touches: when the model offers nothing ("find a time for our NYC trip") or the wrong phrase ("climbing" for "the climbing crew"), code does not add one.

## Sources

- `DynamicGenerationSchema`: https://developer.apple.com/documentation/foundationmodels/dynamicgenerationschema
- Xcode 27.0 SDK: `FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface` (initializers listed above)
- TN3193, on schema token cost: https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
- ADRs 0002, 0009, 0010, 0012, 0014, 0016, 0017, 0160, 0161, 0162
