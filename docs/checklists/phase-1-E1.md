# Phase 1 device checklist: lane E1 (identity and secure channel)

This Mac has no iOS 27 Simulator runtime and no iPhone, so the package was built for iOS but its tests ran only on macOS. Section A needs only Xcode. Sections B and C need the app wired to `StarlingIdentity` (lane H, `docs/requests/E1.md` item 2) and the Wi-Fi Aware transport (lane E2). Write results at the bottom.

## A. Package tests on iOS (Xcode only, about 10 minutes)

1. Xcode > Settings > Components: install the iOS 27 Simulator runtime.
2. Open `Packages/StarlingIdentity/Package.swift` in Xcode. Select the `StarlingIdentity` scheme and an iOS 27 iPhone Simulator.
3. Product > Test. Expect: all tests pass. The real-Keychain suite is skipped.
4. Edit Scheme > Test > Arguments: add the environment variable `STARLING_KEYCHAIN_TESTS` = `1`. Product > Test again. Expect: `identityRoundTripsThroughTheRealKeychain` passes, not error `-34018`. If it fails on the Simulator, repeat on an iPhone if Xcode lets you pick one, and note which.

## B. Pairing on two iPhones (after lanes H and E2 land)

Phone A and Phone B: iOS 27, Starling installed, Wi-Fi Aware already paired in the OS (lane E2 checklist).

1. Both phones: open Pair and pick the other phone. Expect: within 3 seconds, both show a 6-digit code, and the codes are identical.
2. Phone A: tap "Codes match". Phone B: wait 10 seconds without tapping. Expect: Phone A shows "waiting for the other phone" and does not list B as a friend yet.
3. Phone B: tap "Codes match". Expect: both phones list the other as a friend within 2 seconds.
4. Force-quit and reopen Starling on both phones. Expect: each still lists the other (the Keychain kept it). Within 10 seconds, each shows the other as reachable.
5. Remove the friend on both phones. Pair again, but this time tap "Codes don't match" on Phone B. Expect: both phones show a mismatch message, and neither lists the other.
6. Pair again. On Phone A, tap Cancel while the code is showing. Expect: both phones say pairing was cancelled; neither lists the other.
7. Pair again. Tap nothing for 2 minutes. Expect: both phones time out; neither lists the other.
8. Pair for real (steps 1 to 3). Time it from the first tap on Pair, including the OS PIN step. Write the time down (for ADR 0102).

## C. Secure channel on two iPhones (after lanes H and E2 land)

1. With A and B paired, send a Down? intent from A. Expect: B's agent receives it, and the app's debug log shows the sender as A's ID.
2. Walk Phone B out of range (about 30 m, or turn off Wi-Fi on B) for 30 seconds, then come back. Expect: A shows B unreachable within about 15 seconds, then reachable again within 15 seconds of B's return, and messages flow again.
3. Phone B: remove A as a friend (Starling only, not Settings). Phone A: send an intent to B. Expect: B shows nothing, and A shows B as unreachable after the link reconnects.
4. Open Settings > Privacy & Security and find where Wi-Fi Aware pairings are listed (reported as Paired Devices; no Apple doc confirms the path). Write down the path and what is listed. Starling pairings are separate from OS pairings (ADR 0102).

## Results

| Step | Pass/Fail | Notes (times, codes, errors) |
|------|-----------|------------------------------|
| A3 | | |
| A4 | | |
| B1-B8 | | |
| C1-C4 | | |
