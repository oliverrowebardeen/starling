# ADR 0160: Measure model quality with labeled sets, a held-out set, and Evaluations

- Status: Proposed
- Date: 2026-09-30
- Owner: C2. Agent quality

## Context

The Phase 0 bench (`docs/research/model-budget.md`) measured tokens and latency, but judged quality by eye from four utterances and three match cases. It could not tell whether a prompt change helped. Red-team issue #9 then showed that the match cases were all positives, so a matcher that paired everything with everything scored as working.

The brief (section 3.6) asks for the Evaluations framework "to measure negotiation quality as prompts change". Checked against the Xcode 27.0 SDK on this Mac:

- `Evaluations` is available on iOS, macOS, and visionOS 27.0 and Xcode 27.0 (Apple documentation JSON).
- It ships in `Platforms/<platform>/Developer/Library/Frameworks`, next to `Testing` and `XCTest`, not in the SDK's system frameworks. So only test targets can link it, and an app target cannot.
- Its API: `Evaluation` (a dataset `Loader`, `subject(from:)`, an `@EvaluatorsBuilder` list of evaluators, `aggregateMetrics(using:)`), `Evaluator` closures that return a `Metric` (`passing`, `failing`, `scoring`, `ignore`), `ModelSubject`, `EvaluationResult.aggregateValue(_:)`, and a Swift Testing trait `.evaluates(_:)` (from the SDK's `.swiftinterface` and `.swiftdoc`).
- The owner's Mac runs macOS 26.7, so no Evaluations code can run here. CI's `xcode-27` runner is macOS 27 (ADR 0007) but has no Apple Intelligence.

## Decision

1. **Labeled sets live in `StarlingAgentBench`** as plain Swift data: 36 owner utterances with expected rules (`InterpretationSet.labels`), 20 held-out utterances (`InterpretationSet.heldOut`), and 28 match cases, 18 of them negative controls (`MatchSet.labels`). Labels allow tolerance where the owner's words are vague ("tonight" may start between 17 and 20; an activity may have alternative spellings).
2. **Scorers are plain code** (`InterpretationScorer`, `MatchEval`). They report per-field accuracy (days, times, wants, avoids, budget, never-share) and the specific failure modes (over-triggered and missed never-share flags, invented activities, dropped budgets, false matches on negative controls).
3. **Three ways to run them:** `ScriptedAgentModel` in CI (every package test run); `agent-bench --interpretation [--held-out]` and `agent-bench --matching` with the real model on a Mac; and opt-in live tests (`STARLING_MODEL_TESTS=1`).
4. **The held-out set is not used for tuning.** It was written after the grounding checks were tuned on the main set. A fix for a held-out failure must come with fresh held-out items, or the held-out number stops meaning anything.
5. **An Evaluations suite** (`Tests/StarlingAgentEvaluations`) wraps the same sets and scorers, behind `#if canImport(Evaluations)` and `@available(iOS 27, macOS 27)`, in its own test target. It runs against scripted oracles wherever macOS 27 is available (checks the wiring, including in CI), and against the real model with `STARLING_MODEL_TESTS=1`.

## Consequences

- Every prompt or schema change can be measured before and after on the same data. The PR for this ADR does that for interpretation, matching, and decide.
- The sets are small (56 utterances, 28 match cases) and written by one author. Accuracy on them is evidence, not a population estimate, and greedy sampling makes each result a single deterministic sample.
- The Evaluations suite has compiled but never run: macOS 26.7 skips it. Its first run will be CI on macOS 27 or the owner's iPhone (see `docs/checklists/phase-1-C2.md`).
- Linking `Evaluations` into the shared SwiftPM test bundle was checked to still load on macOS 26.7.

## Sources

- Evaluations framework: https://developer.apple.com/documentation/evaluations
- `Evaluation` protocol: https://developer.apple.com/documentation/evaluations/evaluation
- Xcode 27.0 SDK: `Evaluations.swiftmodule/arm64-apple-macos.swiftinterface` and `.swiftdoc`, build 27A266a
- Phase 0 findings: `docs/research/model-budget.md`, section 3
- Red-team issue #9
