# Phase 1 C2 device checklist: agent quality

Checks that the agent fixes hold on iPhone models, and gives the Evaluations suite its first run with a real model (it cannot run on the Mac, which is on macOS 26.7). About 25 minutes with one Apple Intelligence iPhone on iOS 27. Record results at the bottom and send them to the Orchestrator.

## Setup

1. Check out `phase-1/c2-agent-quality`. Run `xcodegen generate --spec App/project.yml && open App/Starling.xcodeproj`.
2. iPhone: iOS 27, Developer Mode on, Apple Intelligence on, connected by cable, unlocked.

## A. Model bench in the app

1. Run the Starling scheme on the iPhone. Tap **Model Bench**, then run it. Expect: "Token counts: Exact", and the run finishes within 3 minutes.
2. Expect in the decide row: **Errors 0** and **Limit violations 0**.
3. Expect the verdict line to say **"Fits the ADR 0002 budget of 2048 tokens per round"**, with the worst call under 2048.
4. Expect in the per-call table: no `accept` or `counter` row lists a violation. Record how each scenario ends. On the Mac, `parent-student` ended in `accept` (a `0 / 0` token row is the accept code makes without the model), `group-4p` in `accept`, and `down-2p` in `reject` at round 5 because no listed option fits both sides.
5. Expect in the match rows: `food-vs-boba` shows `food=boba run`, and no match row pairs `food` with `movie`.
6. Tap **Share report** and save it. Note the variant (`core3` or `coreAdvanced3`).

## B. Evaluations suite on the iPhone (first real run)

1. On the Mac: `cd Packages/StarlingAgent`.
2. Run `xcodebuild -list` and find the iPhone's name with `xcrun xctrace list devices`.
3. Run:
   `TEST_RUNNER_STARLING_MODEL_TESTS=1 xcodebuild test -scheme StarlingAgent-Package -destination 'platform=iOS,name=<iPhone name>' -only-testing:StarlingAgentEvaluations`
   Expect: 4 tests run (none skipped as "Requires macOS 27.0"), and `interpretationSuiteScoresTheOracle` and `matchSuiteScoresTheOracle` pass.
4. Expect `interpretationWithTheRealModel` and `matchingWithTheRealModel` to print per-metric summaries. Record the never-share, budget, and no-false-match means. On the Mac model they were 0.94, 1.00, and about 0.8.
5. If a real-model test fails its threshold, save the full log. That is a finding about the phone model, not necessarily a bug.

## C. Opt-in live tests on the iPhone

1. Run:
   `TEST_RUNNER_STARLING_MODEL_TESTS=1 xcodebuild test -scheme StarlingAgent-Package -destination 'platform=iOS,name=<iPhone name>' -only-testing:StarlingAgentTests/LiveModelTests`
   Expect: `matchRejectsAnUnrelatedOffer` passes (food and movie do not match), and `interpretationSetScores` prints an accuracy table with 0 failed calls.

## Results

| Item | Device, iOS, variant | Result | Notes |
|------|----------------------|--------|-------|
| A2 decide errors / violations | | | |
| A3 worst call (tokens) | | | |
| A4 parent-student / down-2p outcomes | | | |
| B3 oracle suites | | | |
| B4 never-share / budget / no-false-match | | | |
| C1 food vs movie | | | |
