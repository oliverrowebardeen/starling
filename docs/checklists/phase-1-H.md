# Phase 1 device checklist: lane H (App features)

Build: Debug, from `xcodegen generate --spec App/project.yml`, on one iPhone with Apple Intelligence on. Lanes E1, E2, and F are not merged yet, so Down, pairing, and friends run on fakes; Developer > Fakes stands in for the second phone. Delete Starling first so onboarding runs.

## Onboarding

1. Launch Starling. Expect: "Welcome to Starling" with the test-build note. Tap Continue.
2. Tap Continue on "Find friends nearby". Expect: the iOS Local Network alert within 2 seconds. Tap Allow. Expect: "Only real matches" within 2 seconds after answering.
3. Tap "Allow notifications". Expect: the iOS notifications alert. Tap Allow. Expect: the rules editor.
4. Type "No plans before 10. Never share where I am. Vegetarian." and tap "Turn into rules". Expect: a review within about 10 seconds with a Time row (10:00 AM to midnight) and a sharing rule for Place set to "Never share". Any row with an orange note was not in your words.
5. Change or delete any wrong row, tap "Save rules", then Done. Expect: the Down? tab.

## Rules

6. Rules tab. Expect: your saved rules listed in plain words. Tap "Edit rules", change the time, tap "Save rules". Expect: the list shows the new time.
7. Add a "Likes and avoids" rule and leave both fields empty. Expect: a red note and "Save rules" disabled.

## Friends and pairing

8. Friends tab, tap +. Expect: the pairing sheet with the "Nearby phones" placeholder. Tap "Start pairing". Expect: a 6-digit code within 1 second.
9. Tap "Codes are different". Expect: a red warning that someone nearby may be interfering; no friend added.
10. Tap "Try again", then "Codes match", type "Maya", tap Save. Expect: "Paired with Maya"; Done shows Maya in the list.
11. Tap Maya, rename to "Maya R". Swipe left, Unpair, confirm. Expect: the name changes, then Maya disappears.

## Down? and consent

12. Developer > Fakes: tap "Add a sample friend" twice.
13. Down? tab: the status mark at the top shows two shapes apart. Type "free tonight, want food, keep my location to myself", tap "Check with friends". Expect: a review with Time and Activity rows, and a "What may leave your phone" section listing Time, Activity, Budget, Place, Diet, and Group size, each with a "Never share" toggle. If the rules editor saved "never share where I am" in step 4, Place shows on and cannot be turned off. Otherwise turn on "Never share place".
14. Pick Maybe and "1 hour", tap "I'm a maybe". Expect: "You're a maybe until" a time one hour from now, and the mark starts searching (your shape pulses).
15. Developer > Fakes: tap "Send a sample through Outbox". Expect: "Send to <friend>?" listing your free times, food, and $15.00, a note that this build does not hide your free times, and "Says its model runs on their iPhone". Swipe down on the sheet. Expect: it does not close. Wait 2 minutes without answering. Expect: the sheet closes by itself and "It wasn't approved, so nothing left your phone."
16. Tap "Send a sample through Outbox" again. Expect: the sheet again (a timeout is not remembered). Tap "Don't send". Expect: the same "It wasn't approved" message.
17. Tap it again. Expect: the sheet again (a decline is not remembered). Tap Send. Expect: "Sent to <friend> (recorded, not delivered)." Tap it once more. Expect: no sheet, "Sent to <friend>" within 1 second.
18. Tap "Send, with rules changing during consent". Expect: a sheet showing $18.00. Tap Send. Expect: "Your sharing rules changed while you were deciding, so nothing was sent."
19. Tap "Simulate: message from a friend". Expect: "The Down service has received N Inbox events" with N at least 1.
20. Tap "Simulate: checking with friends". Expect: no notification; the Down? tab says "Checking with 2 friends."
21. Tap "Simulate: match (a maybe)". Expect: a banner within 2 seconds, even with Starling open: "You and <friend> are both interested" with the plan. The Down? tab lists the match, and the mark moves together and rests as the logo.
22. Tap "Simulate: match (both down)". Expect: a banner "are both down". Swipe down for Notification Center. Expect: one Starling notification for that friend, not two.
23. Tap "Simulate: Down? expired". Expect: no notification; the Down? tab returns to "What are you up for?" with "Your Down? reached its end time." The mark returns to two shapes apart (after a match there is no "no match" drift).
24. Start a Down? again, then tap "Simulate: Down? failed". Expect: the mark drifts apart and the other shape fades, with no sound or message about a friend, then rests apart within 3 seconds.
25. Start a Down? again, then tap Withdraw. Expect: back to the start with no notification, and the mark goes straight to apart.

## Release build

26. In Xcode, Product > Scheme > Edit Scheme > Run > Build Configuration: Release. Run. Expect: Down? and Friends say "isn't in this build yet", Developer shows only Model Bench and "Release (no fakes)". Set it back to Debug.
