# ADR 0161: Ground interpreted rules in the owner's words

- Status: Proposed
- Date: 2026-09-30
- Owner: C2. Agent quality

## Context

Phase 0 found interpretation "usable only with owner review" (`docs/research/model-budget.md`, finding 5). On the 36-utterance labeled set (ADR 0160), the Phase 0 agent got all six fields right on 2 utterances. Raw model output from the Phase 1 runs showed why:

- The prompt's `Now: Tue 12:00` line anchored the model to "today, 12 to 23" when the owner named no time.
- The small model almost never filled optional `Int` fields: budgets landed in the activity list (`"$25"`), and clock hours came back nil or on a 12-hour clock (`"at 7"` as 7).
- The three never-share Bools flipped together whenever the message mentioned sharing.
- Activities were invented ("coffee, sandwich" from "anything but sushi") or copied from rule fragments ("not far", "share schedule").

Four schema and prompt variants were measured. They helped the day and budget fields but did not fix never-share or invented activities: an evidence-quote field made over-triggers worse (10 to 28), and three-state enums per field reached 20. Enums with a leading `none` case were filled reliably, and non-optional hours and budget with explicit "not stated" sentinels (0, 24, 0) fixed the dropped budgets.

## Decision

1. **Schema:** a day enum with `none` first plus `tonight`; a part-of-day enum (`morning`, `lunch`, `afternoon`, `evening`) that fills hours only when none were stated; non-optional hours and budget with sentinels; no clock in the prompt.
2. **Grounding in code** (`Grounding.check`), applied to every interpretation before mapping. A value survives only if the owner's message supports it:
   - an activity must share a word with the message and must not be a rule fragment (negations, prices, times, sharing words, pronouns); an avoid loses a leading "no" instead of being dropped
   - a budget, day, part of day, or clock hour must be stated (digits, number words, "noon", "midnight", or the day's name)
   - a never-share flag needs both a privacy word (share, tell, private, secret, know, hide, reveal, disclose) and a word naming that field
   - stated hours go on a 24-hour clock: "at 7" means 19 unless the message says "am" or "morning"
3. Grounding never adds a value. The owner still reviews every interpretation (brief 2.5).

## Consequences

Measured with the real model on this Mac (macOS 26.7), Phase 0 agent to this ADR:

| Set | All six fields correct | Never-share over-triggered | Never-share missed | Invented activities | Dropped budgets |
|-----|-----------------------:|---------------------------:|-------------------:|--------------------:|----------------:|
| Tuning (36) | 2 to 31 | 10 to 1 | 2 to 1 | 15 to 0 | 2 to 0 |
| Held-out (20) | 2 to 12 | 7 to 0 | 1 to 2 | 8 to 1 | 4 to 2 |

- **The word lists are English only**, and a fixed list misses phrasing it does not contain. The held-out set shows the cost in the privacy-relevant direction: "keep my location to myself" and "keep my plans private" lost their never-share flag, because "myself" is not a privacy word and "plans" does not name the schedule. Missed flags rose from 1 to 2 on the held-out set. The owner's review step, with every never-share toggle shown, is the backstop; lane H should make that review impossible to skip.
- Over-triggering is the usability failure (a budget hidden for no reason breaks matching); missing is the privacy failure. This design trades a few misses for far fewer over-triggers. If misses matter more, the check could keep flags when either word is present, at the cost of most of the over-trigger fix.
- The checks were tuned on the 36-utterance set, which is why the held-out number (60%) is well below the tuning number (86%).
- A non-English owner gets the model's raw never-share flags filtered to nothing. Localization needs its own word lists, or a different approach.

## Sources

- ARCHITECTURE.md rule 6 ("the model proposes; code enforces")
- Phase 0 findings: `docs/research/model-budget.md`, finding 5
- TN3193, on property order and schema size: https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
- Measurements: `Packages/StarlingAgent/Reports/phase-1-quality.md`
