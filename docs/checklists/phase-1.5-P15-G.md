# Device checklist: Phase 1.5 lane P15-G (pairing)

About five minutes. Phone A is Oliver's iPhone, Phone B is a friend's iPhone, both on this branch's Debug build. The steps call Phone A's owner Maya and Phone B's owner Riley, with phones named "Maya's iPhone" and "Riley's iPhone".

- To see the notification step, delete Starling from Phone A before installing. That resets its notification answer.
- Old Wi-Fi Aware pairings between the phones can stay; step 2 covers both cases.
- If any step fails, open You › Developer › Pairing log on both phones, tap Share, and attach both logs to issue #95. They never contain a code or a key.

## Pair

1. Both phones: Friends › Add friend. Allow Local Network if asked. Expect: within 1 second, a centered "Hold your phones close" with Find their phone and Let them find me.
2. Phone B: tap Let them find me. Phone A: tap Find their phone, pick Phone B, and type the PIN if the system asks (first time only).
   - Expect on Phone A: a centered "Connecting to <Phone B's name>".
   - Expect within 15 seconds: both phones show the same 6-digit code under "Check the code", Phone B without any other tap.
   - If the system picker does not list Phone B: close it, and on Phone A tap Phone B under "Or pick their phone". Expect the same.
3. Phone A: tap They match. Expect: a centered "Waiting for the other phone".
4. Phone B: tap They match. Expect within 2 seconds, on both phones: "What do you call them?" prefilled with a first name ("Riley" on A, "Maya" on B), never "Riley's iPhone". There is no Close button, and a swipe down does nothing.
5. Phone A: keep or edit the name, then tap Done. Expect: "Get a heads-up when Riley wants to make plans", with Continue as the only button.
6. Phone A: tap Continue. Expect: the iOS notification alert at once. Allow. Expect: "You're paired". Tap Done.
7. Both phones: Friends. Expect: the friend under the name you chose, with a pair symbol and the green dot within 15 seconds.
8. Write down the time from step 1 to step 6, and how many tries it took. Target: under 60 seconds, first try.

## Recover

9. Both phones: unpair (Friends › the friend › Unpair). Phone A: Add friend, pick Phone B under "Or pick their phone". When the code shows, turn Wi-Fi off on Phone B for 3 seconds, then back on.
   - Expect: the codes stay, and both pair after They match on both phones.
   - Or, if a phone shows "Pairing didn't finish": tap Try again on that phone only. Expect: both phones show a new matching code within 10 seconds, with no tap on the other phone.
10. Unpair both again. Phone A: Add friend, pick Phone B, then tap Cancel while it says Connecting. Expect: Phone A shows "Pairing didn't finish" and stays there. Phone B returns to "Hold your phones close", or shows "Pairing didn't finish", within 5 seconds.

## Notifications declined

11. Phone B: delete Starling, reinstall, and pair with Phone A again (steps 1 to 4). At "Get a heads-up…", tap Continue, then Don't Allow. Expect: "You're paired".
12. Phone B: open You. Expect: a quiet "Notifications are off" row with a Settings button near the top. Tap Settings. Expect: Starling's notification settings.
13. Phone B: unpair and pair with Phone A once more. Expect: no "Get a heads-up…" step.

## Links

14. Both phones: force-quit Starling and open it again. Expect: the friend's green dot within 15 seconds on both.
15. Phone A: You › Developer › Pairing log. Expect:
    - Wi-Fi Aware lines that include "settled as publisher" or "settled as subscriber".
    - A "link to … is active" line.
    - No 6-digit code anywhere.

## Results

| Step | Pass/Fail | Notes (times, tries, errors) |
|------|-----------|------------------------------|
| 1-8 | | |
| 9-10 | | |
| 11-13 | | |
| 14-15 | | |
