# Phase 0 device checklist

Closes the Phase 0 exit criteria: two iPhones exchange typed messages over LocalP2P, and the model bench reports tokens and latency per round on real hardware. About 20 minutes with two phones, or use the one-phone-plus-Mac variant of section A.

Record results at the bottom and paste the model reports into `docs/research/model-budget.md` section 4 (or send them to the Orchestrator).

## Setup (once)

1. Install **Xcode 27** from the Mac App Store, open it, and let it install the iOS 27 platform.
2. Run `brew upgrade xcodegen` (2.46.0 or later).
3. Create `App/Config/Local.xcconfig` containing one line: `DEVELOPMENT_TEAM = <your team ID>`. It is gitignored.
4. Run `xcodegen generate --spec App/project.yml && open App/Starling.xcodeproj`.
5. On each iPhone: iOS 27, Developer Mode on, and Apple Intelligence on (Settings > Apple Intelligence & Siri).
6. Build and run the Starling scheme on Phone A, then on Phone B.

## A. LocalP2P (two iPhones)

1. Both phones: tap **Nearby**, then **Start**. Expect: a Local Network permission prompt. Tap Allow. Expect: log line "Listening as XXXXXXXX on starling-..." within 1 second.
2. Expect: within 5 seconds each phone lists the other's 8-character ID under "Nearby phones", and the log says "Found XXXXXXXX".
3. Phone A: tap **Send proposal** next to Phone B's ID. Expect within 2 seconds: Phone B logs "<- propose from <A>: activity boba; budget 12 USD; time ..."; Phone A logs "<- accept from <B>, round trip N ms".
4. Repeat step 3 nine more times. Write down the round-trip times. Expect: 10 of 10 accepted.
5. Phone B: tap **Send proposal** to Phone A once. Expect the mirror of step 3.
6. Both phones: Settings > Wi-Fi, stay on but tap the joined network's (i) and **Forget** it (or walk somewhere with no shared network). Return to Starling, Stop, then Start. Repeat step 3. Expect: it still works over peer-to-peer Wi-Fi.
7. Phone B: tap **Stop**. Expect: Phone A logs "Lost <B>" within 2 seconds.
8. Informational: Phone B, Start again, then swipe to the Home Screen for 30 seconds and come back. Note what Phone A's log shows.

## A (variant). One iPhone plus this Mac

Use this until a second iPhone is available. It proves the transport and message format between two devices, but not phone-to-phone radio behavior, so run section A with two phones later (for example with a friend) to close the exit criterion fully.

1. Mac: `cd Tools/Peer && swift run starling-peer`. If macOS asks for Local Network access, allow it. Expect: "Listening as XXXXXXXX".
2. Phone: tap **Nearby**, then **Start**. Expect within 5 seconds: the Mac prints "Found XXXXXXXX (1)" and the phone lists the Mac's ID.
3. Phone: tap **Send proposal** next to the Mac's ID. Expect within 2 seconds: the Mac prints "<- propose from ..." and "-> accept to ..."; the phone logs "<- accept ..., round trip N ms".
4. Mac: type `send 1` and press Return, ten times. Expect: the phone logs each proposal; the Mac prints each round trip. Then type `stats` and record the line.
5. Peer-to-peer Wi-Fi: disconnect both devices from any Wi-Fi network while leaving Wi-Fi on (Mac: Option-click the Wi-Fi menu, then Disconnect). Restart both (Mac: `quit`, run again; phone: Stop, Start). Repeat step 3. Expect: it still works.
6. Mac: type `quit`. Expect: the phone logs "Lost <Mac ID>" within 2 seconds.

## B. Model bench (each Apple Intelligence iPhone)

1. Tap **Model Bench**. Record Availability, Variant, Context size, and Token counts. Expect "Available" and "Exact" (Exact needs an Xcode 27 build).
2. Set Repetitions to 3 and tap **Run bench**. Keep the screen on and the app in front. Expect: it finishes within 3 minutes with no errors in the Progress list.
3. Tap **Share report** and save or send the Markdown.

## C. Simulator check (Mac, optional)

1. With Xcode 27 selected (`sudo xcode-select -s /Applications/Xcode.app`), run:
   `cd Packages/StarlingAgent && TEST_RUNNER_STARLING_MODEL_TESTS=1 xcodebuild test -scheme StarlingAgent-Package -destination "platform=iOS Simulator,name=iPhone 17 Pro" -only-testing:StarlingAgentTests/LiveModelTests`
2. Record pass or fail. (It failed on the iOS 26.1 Simulator with a missing-assets error.)

## Results

| Item | Phone A | Phone B |
|------|---------|---------|
| Model and iOS version | | |
| A2: discovered within 5 s? | | |
| A4: round trips (min / median / max ms) | | |
| A4: accepted out of 10 | | |
| A6: works with no shared Wi-Fi? | | |
| A7: "Lost" within 2 s? | | |
| A8: background behavior | | |
| B1: variant, context size | | |
| B2: finished? errors? | | |
| C: Simulator model test | | |
