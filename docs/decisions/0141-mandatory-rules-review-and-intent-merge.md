# ADR 0141: Mandatory review of interpreted rules, and merging rules into Down intents

- Status: Accepted (code merged on main; status updated 2026-10-06)
- Date: 2026-09-30
- Owner: H (App features)

## Context

Brief 2.5 has the owner describe rules in plain language, which the model turns into constraints "the user can review". The Phase 0 bench measured interpretation inventing activities and sharing flags and dropping budgets (`docs/research/model-budget.md`). Architecture section 7 step 1 has the owner review and edit the interpreted `OwnerRules` before `DownService.setIntent`.

`DownService.setIntent` takes one `DownIntent` with one `OwnerRules`. The owner has two sources of rules: standing rules saved at setup ("never share where I am") and the intent of the moment ("free tonight, want food").

## Decision

1. **Review is structural, not a suggestion.** Interpretation produces a `RulesDraft`, an editable copy. Saving (`RulesEditorModel.save`) and publishing (`DownModel.goDown`) work only from the review phase and only when `RulesDraft.build()` validates every row. No code path goes from `AgentModel.interpret` to storage or to `DownService` without it.
2. **Review flags point at likely inventions.** Deterministic string checks mark model-produced rows the owner's words do not support: keywords not in the text (plurals allowed), amounts, hours, and counts whose numbers are not in the text, and every "share without asking" rule. Flags are advisory; rows the owner added are never flagged. This is plain logic, not a second model call (brief 2.4: the model must earn its place).
3. **When the model cannot run** (ineligible iPhone, the Simulator, `AgentModelError.unavailable`), the owner writes rules by hand in the same review form rather than being blocked.
4. **Standing rules are merged into every intent** before `setIntent` (`RulesMerge.intent`): constraints on the same issue accumulate (all must hold), the intent's first, because lane F reads liked keywords in order and the intent of the moment should outrank a standing preference, and for sharing the most restrictive action per issue wins (`never` over `askEachTime` over `allowOnDevicePeers`), so an intent can never loosen a standing "never". A merge that breaks a `ConstraintSet` limit keeps the review open with an explanation. Sharing merges separately from constraints and cannot fail. If saved rules change while an intent is out and the combined constraints break a limit, the app fails closed: the policy blocks every send, the intent ends with a notice, and only then does the policy return to the saved rules. It never falls back to the saved rules alone while the intent is out, which would drop the intent's own "never share" rules.
5. **Every sharing setting is always on screen.** The review shows a row for each disclosable issue (time, activity, budget, place, diet, group size, plus any other issue the rules mention), each with a "Never share" toggle, whether or not the interpreted rules mention it. Lane C2 measured interpretation missing a never-share phrased in words its grounding lists do not know ("keep my location to myself", ADR 0161 on the C2 branch), so the owner must be able to see and set every one. A row with no rule reads "Ask me each time", which is what lane G's policy does for an issue without a rule; choosing it writes no rule. In the Down review, a saved sharing rule is a floor: the row shows the effective action, and choices looser than the saved rule are not offered. If the saved sharing changes while a Down review is open (edited in the Rules tab), publishing stops, the rows refresh, and the owner confirms again.

   Only saved *sharing* is re-confirmed, not saved constraints (time windows, budget, and so on), for two reasons. The Down review displays saved sharing (as the rows above) but never displays saved constraints; it says "Your saved rules also apply", so there is no on-screen claim about them that an edit could make false. And sharing decides what leaves the phone, while constraints only bound what the owner's own agent will accept: a saved constraint edited moments ago in the Rules tab is the owner's current, reviewed choice, applied the same way whenever an intent goes out. If the Down review ever shows saved constraints, it must re-confirm them the same way.
6. Standing rules are stored in `Application Support/Starling/rules.json`, excluded from backup, with `completeFileProtectionUntilFirstUserAuthentication`, matching the Keychain class ADR 0003 chose so background work after first unlock can read them.

## Consequences

- Review is not skippable: `RulesEditorModel.save` and `DownModel.goDown` work only from the review phase (tests `interpretationOpensAReviewAndDoesNotSave`, `goingDownRequiresTheReviewStep`), and the sharing rows are tested in `SharingRowTests`.

- If lane F prefers to receive standing rules separately (for example to treat them differently in negotiation), `DownIntent` would need a change through `docs/requests/F.md`; until then the merged rules are the contract.
- Flags will miss inventions that happen to reuse the owner's words and will flag correct rows phrased differently ("fifteen dollars"). They reduce review effort; they do not replace it.

## Sources

- Lane C2, ADR 0161 (branch `phase-1/c2-agent-quality`): held-out phrasings that lost their never-share flag.

- Brief sections 2.4, 2.5, 3.5; ARCHITECTURE.md section 7.
- Phase 0 interpretation findings: `docs/research/model-budget.md`.
- `Data.WritingOptions.completeFileProtectionUntilFirstUserAuthentication`: https://developer.apple.com/documentation/foundation/nsdata/writingoptions/completefileprotectionuntilfirstuserauthentication
