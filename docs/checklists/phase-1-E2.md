# Phase 1 device checklist: Wi-Fi Aware transport (lane E2)

## Before you start

1. In the developer portal, enable the **Wi-Fi Aware** capability for the App ID `com.oliverrowebardeen.starling`. Nothing Wi-Fi Aware works without it.
2. Two iPhones, iPhone 12 or later, both on iOS 27. Wi-Fi on, Bluetooth on. Wi-Fi Aware does not run in the Simulator.
3. A build with lane H's wiring from `docs/requests/E2.md` section 3: the ADR 0111 entitlement and Info.plist entries, the pairing screen, and a per-friend connection indicator with a round-trip button.
4. Run from Xcode on both phones if you can. Debug builds log lines starting with `[WiFiAware` to the console, which helps if a step fails.

Record every "Expect" that does not happen, with the time you waited and any on-screen error.

## Pairing

1. Phone A: open the pairing screen and tap the button in the pairing view ("make discoverable"). Expect: a system sheet within 2 seconds saying the phone is discoverable.
2. Phone B: tap the button in the device picker. Expect: a full-screen system picker that lists Phone A within 10 seconds.
3. Phone B: select Phone A. Expect: a code or PIN on one or both phones within 5 seconds. Write down exactly what each phone shows and asks for (this answers an open research item), then complete it.
4. Both: expect the other phone in the app's paired-devices list within 5 seconds of finishing, and under Settings > Privacy & Security (write down the exact menu path you found it under).

## Link

5. Both: stay on a screen where the transport runs. Expect: each phone shows the other as connected within 10 seconds of pairing, with no further taps.
6. Phone A: tap the round-trip button 5 times. Expect: 5 replies, each under 200 ms. Write down the times. Repeat from Phone B.
7. Pairing while linked: on Phone B, remove Phone A in Settings, then pair again (steps 1 to 4) **while the transport is still running** on both. Expect: pairing works, and the phones reconnect within 10 seconds. If the pairing sheet fails here, write down the error: ADR 0111 has a fallback for it.

## Reconnect

8. Walk Phone B away until the indicator on Phone A shows disconnected, or 60 m or two walls away. Expect: Phone A shows B as disconnected within 15 seconds of losing range.
9. Walk back next to Phone A. Expect: both show connected again within 20 seconds, without touching either phone. Then repeat step 6 once.
10. Phone B: force-quit the app and open it again. Expect: both show connected within 10 seconds of the app opening, and Phone A lists Phone B once, not twice.
11. Force-quit on both, then open both. Expect: they connect within 10 seconds with no pairing sheet (the pairing lasted).

## Unpairing

12. Phone B: remove Phone A in Settings. Expect: Phone A disappears from B's paired list within 5 seconds, B shows it as disconnected, and neither app crashes.
