# Model budget: tokens and latency per negotiation round

Phase 0 spike report. Answers brief open question 5 ("does 4096 tokens suffice?") as far as a Mac can.

Status: Mac numbers only.

> **Correction (2026-09-30):** the Phase 0 token numbers below were character-based estimates, and they were too low. With Xcode 27, `tokenCount(for:)` counts real tokens: the same Phase 0 workloads peak at **874 tokens, not about 494** (interpret 794 in / 80 out; decide 793 / 54; match 454 / 112), so the estimate understated real size by roughly 1.8 times. After lane C2's Phase 1 changes, the worst call is **1,428 tokens** (a 6-by-10 keyword match): 35% of a 4,096-token window and about 70% of the ADR 0002 per-round budget of 2,048. The conclusion holds, but the margin is much smaller than section 3 says. Full before and after reports: `Packages/StarlingAgent/Reports/phase-1-quality.md` (lane C2, PR #19).

## 1. Method

`Packages/StarlingAgent` implements `AgentModel` with FoundationModels. `StarlingAgentBench` runs fixed workloads through it:

| Workload | What the model sees | Size driver |
|----------|---------------------|-------------|
| `decide: down-2p` | Two friends; time, activity, budget | 3 issues, 2 time and 3 activity options |
| `decide: group-4p` | One agent weighing a proposal against four friends' pooled options | 4 issues, 7 time and 8 activity options (near the renderer caps of 8 and 10) |
| `decide: parent-student` | Calendar parent, no-calendar student, weekend time | 1 issue, 3 to 4 slots, daily window |
| `interpret` x4 | Owner's plain-language rules and intent | 9-property schema |
| `match` x3 | Wants vs offers, up to 6 x 10 keywords | List length |

Each call runs in a fresh session with greedy sampling (ADR 0002), so a negotiation's cost is per round, not cumulative. Negotiations alternate sides for up to 6 rounds.

Run it:

- Mac: `cd Packages/StarlingAgent && swift run agent-bench --repetitions 3 --json bench.json`
- iPhone: the app's Model Bench screen (see the Phase 0 device checklist).

Token counts come from `tokenCount(for:)` on SDKs 26.4 and later. Input includes the schema counted separately, so it is an upper bound. On older SDKs the bench estimates tokens at 3.5 characters per token (TN3193 says three to four for English) and labels the report "estimated".

## 2. Mac results (2026-09-29)

Host: M5 MacBook, 16 GB, macOS 26.7, Xcode 26.1.1. **Caveats:** this is the macOS 26 on-device model, not the iOS 27 models (AFM 3 Core, AFM 3 Core Advanced); tokens are **estimates** because the 26.1 SDK has no `tokenCount(for:)`; latency is a Mac, not a phone.

Three runs, changing only the prompt and schema:

| Run | Change | decide: violations / calls | decide tokens in max / out max | Worst call (tokens) | decide latency p50 / max |
|-----|--------|---------------------------:|-------------------------------:|--------------------:|-------------------------:|
| 1 | Baseline | 3 / 3 | 415 / 23 | 437 | 1147 / 3213 ms |
| 2 | Proposal items that break a hard limit marked `BREAKS LIMIT` in the prompt | 6 / 6 | 421 / 23 | 443 | 921 / 2167 ms |
| 3 | Run 2, plus a `brokenItems` field generated **before** `move` | 2 / 8 (1 invalid output rejected) | 463 / 34 | 494 | 1181 / 1841 ms |

Other tasks (run 3): `interpret` 434 in / 61 out max, p50 1411 ms; `match` 260 in / 71 out max, p50 1123 ms.

Note (after the Codex review): run 3 had one failed call (an invalid option, not a context overflow), so it has no token count. The corrected bench now reports such a run as "incomplete" rather than "fits". The finding below still stands because the failure was not about size, but device runs should aim for zero unmeasured calls.

## 3. Findings

1. **Budget: fits, with less margin than first estimated.** The worst single call was about 494 tokens by the Phase 0 estimate; real counting later showed 874 (see the correction above), and 1,428 after Phase 1's richer schemas. Per-round cost is flat because each round is a fresh session. Unless device counts come in several times higher than these estimates, **4096 fits realistic two-party and four-party rounds.**
2. **Latency: about 1 to 3 s per call on a Mac.** A 3-round negotiation is 3 to 9 s of model time before network time. Phones will be slower; this is the number the device run most needs to pin down. It already argues for doing single-issue and hard-limit logic in code (zero model calls).
3. **The model must not enforce hard limits.** Baseline: it accepted every proposal that broke a limit. Marking the conflicts in the prompt did not help (6 of 6). Generating the list of broken items before the move cut violations to 2 of 8 and produced real counters that converged in 2 to 5 rounds, but still not zero. **Rule for the Negotiation lane:** check hard limits in code before and after every model call; the model only chooses among options already known to be compliant. `HardLimits` is the Phase 0 version of that check.
4. **Schema property order matters.** The model writes properties in order; a reasoning-style field first changed behavior more than any wording change.
5. **Interpretation is usable only with owner review.** Core facts come through (times, "after 8 tonight", budgets, weekday names once a `DayName` enum replaced day-offset arithmetic). But any sentence about sharing flips every "never share" flag, activities get invented ("walk, coffee, movie" from "anything but sushi"), and one run dropped a stated $20 budget. The brief's review step is not optional; this task needs the most prompt work in Phase 1.
6. **Fuzzy matching is the model's best job.** "noodles = ramen", "something sweet = ice cream", "cheap eats = tacos", "study = library" across all runs, with one dubious pair ("food = movie", marked as weaker).
7. **Output validation earns its keep.** One run tried an activity option in a time-only scenario; `OutputMapping` rejected it as `invalidOutput` instead of passing it on.

## 4. Device results

This report has Mac numbers only. The bench runs on a phone the same way, and its report header records the model variant (`core3` or `coreAdvanced3`) and context size.

## 5. Answer to open question 5

- **Tokens:** yes, 4096 is enough for realistic rounds, provided each round runs in a fresh session with a compact typed summary instead of a growing transcript. Real counts (1,428 worst after Phase 1) leave about 30% headroom under the 2,048 per-round budget, so option-list caps in the prompt renderer matter.
- **Multi-party:** four-party pooled options raised input by about 100 tokens over two-party. Size scales with option-list length, which the renderer caps (8 time, 10 activity options).
- **Weaker iOS 27 model:** not measured in this report. The Mac model already needs code-enforced limits, and the code enforces them whichever model runs.
- **Not measured in this report:** Evaluations framework runs (needs Xcode 27; Phase 1 Agent lane), PCC comparison, and background-task throttling.
