# Phase 1 device checklist: F. Negotiation (Down?)

Lane F ships a library (`StarlingNegotiation.DownNegotiator`), not a screen. Run steps 2 to 9 once lane H has wired it into the Down screen, on two phones paired through lane E1 and E2's flow. The PSI stub is not private, so the policy asks for consent on PSI frames: approve every consent sheet unless a step says otherwise. Times below are examples; use a window that starts after the current time.

## On the Mac (no phone)

1. Run `Tools/test-all.sh Packages/StarlingNegotiation`. Expect: `Test run with 73 tests in 6 suites passed`.

## Two paired phones, A and B, both in the app and on the same network

2. Phone A: set Down "free 7 to 10 tonight, want food, under $15", level Down. Phone B: set Down "free 8 to 11 tonight, boba, under $20", level Down. Expect: within 15 seconds, both phones show one match: 8:00 to 10:00, $15, with an activity (food or boba), marked as both Down.
3. Leave both phones on the Down screen for 1 minute after step 2. Expect: no second match notification on either phone.
4. Clear Down on both phones. Phone A: set Down "free 7 to 10 tonight", level Maybe. Phone B: set nothing. Wait 1 minute. Expect: no notification and no consent sheet on phone B; no match on phone A.
5. Phone B: now set Down "free 8 to 11 tonight", level Down (phone A still has Maybe from step 4). Expect: within 15 seconds, both phones show a match that is not marked as both Down.
6. Clear Down on both. Phone A: "free 7 to 8 tonight". Phone B: "free 9 to 11 tonight". Wait 1 minute. Expect: no match and no notification on either phone.
7. Clear Down on both. Phone A: "free 7 to 10 tonight, want climbing, no movies". Phone B: "free 7 to 10 tonight, want a movie, no climbing". Wait 1 minute. Expect: no match on either phone.
8. Clear Down on both. Phone A: set Down "free 7 to 10 tonight". On phone B, set the same, then decline the first consent sheet it shows. Expect: no match on either phone within 1 minute.
9. Clear Down on both. Phone A: set Down "free 7 to 10 tonight". Walk phone B out of range (or turn its Wi-Fi off) and set the same Down on it. After 30 seconds, bring it back (or turn Wi-Fi on). Expect: no match while apart; a match on both phones within 30 seconds of reconnecting.

## Report back

For step 2, note how long the match took on each phone. Model calls are about 1 to 3 s on a Mac; phone timings decide whether the 5-second retry interval needs to grow.
