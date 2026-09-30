# ADR 0141: Mandatory review of interpreted rules, and merging rules into Down intents

- Status: Proposed
- Date: 2026-09-30
- Owner: H (App features)

## Context

Brief 2.5 has the owner describe rules in plain language, which the model turns into constraints "the user can review". The Phase 0 bench measured interpretation inventing activities and sharing flags and dropping budgets (`docs/research/model-budget.md`). Architecture section 7 step 1 has the owner review and edit the interpreted `OwnerRules` before `DownService.setIntent`.

`DownService.setIntent` takes one `DownIntent` with one `OwnerRules`. The owner has two sources of rules: standing rules saved at setup ("never share where I am") and the intent of the moment ("free tonight, want food").

## Decision

1. **Review is structural, not a suggestion.** Interpretation produces a `RulesDraft`, an editable copy. Saving (`RulesEditorModel.save`) and publishing (`DownModel.goDown`) work only from the review phase and only when `RulesDraft.build()` validates every row. No code path goes from `AgentModel.interpret` to storage or to `DownService` without it.
2. **Review flags point at likely inventions.** Deterministic string checks mark model-produced rows the owner's words do not support: keywords not in the text (plurals allowed), amounts, hours, and counts whose numbers are not in the text, and every "share without asking" rule. Flags are advisory; rows the owner added are never flagged. This is plain logic, not a second model call (brief 2.4: the model must earn its place).
3. **When the model cannot run** (ineligible iPhone, the Simulator, `AgentModelError.unavailable`), the owner writes rules by hand in the same review form rather than being blocked.
4. **Standing rules are merged into every intent** before `setIntent` (`RulesMerge.intent`): constraints on the same issue accumulate (all must hold), and for sharing the most restrictive action per issue wins (`never` over `askEachTime` over `allowOnDevicePeers`), so an intent can never loosen a standing "never". A merge that breaks a `ConstraintSet` limit keeps the review open with an explanation.
5. Standing rules are stored in `Application Support/Starling/rules.json`, excluded from backup, with `completeFileProtectionUntilFirstUserAuthentication`, matching the Keychain class ADR 0003 chose so background work after first unlock can read them.

## Consequences

- If lane F prefers to receive standing rules separately (for example to treat them differently in negotiation), `DownIntent` would need a change through `docs/requests/F.md`; until then the merged rules are the contract.
- Flags will miss inventions that happen to reuse the owner's words and will flag correct rows phrased differently ("fifteen dollars"). They reduce review effort; they do not replace it.

## Sources

- Brief sections 2.4, 2.5, 3.5; ARCHITECTURE.md section 7.
- Phase 0 interpretation findings: `docs/research/model-budget.md`.
- `Data.WritingOptions.completeFileProtectionUntilFirstUserAuthentication`: https://developer.apple.com/documentation/foundation/nsdata/writingoptions/completefileprotectionuntilfirstuserauthentication
