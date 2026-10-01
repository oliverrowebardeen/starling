# Phase 1 device checklist: lane H (App features)

Build: Debug, from `xcodegen generate --spec App/project.yml`, signed, on one iPhone with Apple Intelligence on (a Simulator run needs Sign to Run Locally: without signing the app stops at "This build isn't signed, so it can't use the Keychain"). Everything is real except the PSI stub: lane E1's identity, pairing, and secure links, lane G's policy and consent sheet, and lane F's Down. A simulated friend inside the app (Developer > Simulated friend) stands in for a second phone over a secure in-process link. Delete Starling first so onboarding runs.

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

8. Friends tab. Expect: "Sim friend" with a green dot within 5 seconds (its secure session is up). Tap Sim friend, rename to "Sim F", Save. Expect: the name changes (Debug only; Release does not offer rename until lane E1's rename lands).
9. Tap +. Expect: the pairing sheet. On a Wi-Fi Aware iPhone, "Let a friend find this phone" and "Find a friend's phone"; elsewhere, a note that this iPhone can't pair over Wi-Fi Aware. Below: "Phones nearby", "This phone is" followed by 8 characters, a name field, and Pair disabled. With one phone, expect "Looking for nearby phones..." and nothing to pick. Close.
10. Developer > Fakes: tap "Add a sample friend". Friends tab: swipe left on it, Unpair, confirm. Expect: it disappears.

Two phones (A and B, both on this build) for steps 11 to 14; run lane E1's checklist section B at the same time:

11. Both: Friends > +. On Wi-Fi Aware iPhones: Phone A taps "Let a friend find this phone"; Phone B taps "Find a friend's phone" and picks A. Expect on B, within 15 seconds of the system pairing: A selected in "Phones nearby" and the name field filled with A's device name. On A (or on phones without Wi-Fi Aware), expect within 5 seconds the other phone listed as "Phone" plus its 8 characters, with its label (Wi-Fi Aware or Nearby). Check each phone shows the other's "This phone is" number.
12. Both: pick the other phone, type a name, tap Pair. Expect: both show the same 6-digit code within 3 seconds. Phone A: "Codes match". Expect: A shows "Waiting for the other phone...". Phone B: "Codes match". Expect: "Paired with <name>" on both within 2 seconds, and the friend in the list with a green dot within 10 seconds.
13. Pair again but tap "Codes are different" on B. Expect: a red warning that someone nearby may be interfering on B, a failure on A, and no new friend on either.
14. On A, swipe B away and Unpair. Expect: B disappears from A's list, and B's dot for A turns grey within 15 seconds. Pair again to continue.

## Down? and consent

Developer > Simulated friend is a second phone inside the app, paired with this one and reachable from launch. It runs lane F's real Down, so consent sheets below are real policy decisions. Answer each sheet within 30 seconds: lane F drops a step the owner has not answered by then.

15. Friends tab. Expect: "Sim friend" listed. Developer > Fakes: tap "Add a sample friend" twice (they are never reachable).
16. Down? tab: the status mark at the top shows two shapes apart. Type "free tonight, want food, keep my location to myself", tap "Check with friends". Expect: a review with Time and Activity rows, and a "What may leave your phone" section listing Time, Activity, Budget, Place, Diet, and Group size, each with a "Never share" toggle, plus a note that matching does not hide your free times. If the rules editor saved "never share where I am" in step 4, Place shows on and cannot be turned off. Otherwise turn on "Never share place".
17. Pick Maybe and "1 hour", tap "I'm a maybe". Expect: "You're a maybe until" a time one hour from now, the mark starts searching, "Checking with 1 friend", and within 5 seconds a sheet asking to send Availability to Sim friend. Tap "Don't send". Expect: no more sheets for this Down? and no notification. Tap Withdraw.
18. Developer > Fakes: tap "Send a sample through Outbox". Expect: "Send to Sim friend?" with rows Availability (a UTC time range, "end excluded"), Activity "boba run", and Budget "12.00 USD"; "Recipient declares an on-device model."; and notes that the location is self-declared and that each message also sends identifiers and protocol metadata. Swipe down on the sheet. Expect: it does not close. Wait 2 minutes without answering. Expect: the sheet closes by itself and "It wasn't approved, so nothing left your phone."
19. Tap "Send a sample through Outbox" again. Expect: the sheet again (a timeout is not remembered). Tap "Don't send". Expect: the same "It wasn't approved" message.
20. Tap it again. Expect: the sheet again (a decline is not remembered). Tap Send. Expect: "Sent to Sim friend." Tap it once more. Expect: no sheet, "Sent to Sim friend" within 1 second.
21. Tap "Send, with the policy changing during consent". Expect: a sheet showing Budget "18.00 USD". Tap Send. Expect: "Your sharing rules changed while you were deciding, so nothing was sent."
22. Developer > Audit log. Expect: two "hello to Sim friend" entries from launch (the greeting and the answer to Sim friend's) and exactly two "propose to Sim friend" entries (step 20), each listing Activity: keywords, Budget: amount, Time: slots, and no values. The declined, timed-out, and refused sends are not listed.
23. Rules tab > Edit rules: turn on "Never share budget", Save. Developer > Fakes: tap "Send a sample through Outbox". Expect: no sheet, "Your sharing rules don't allow this, so nothing was sent." Turn "Never share budget" off again and save.
24. Developer > Simulated friend: tap "Sim friend: I'm down". Expect: "Down: food or boba, up to $20, next 8 hours".
25. Down? tab: type "free in the next two hours, want food, under $15", tap "Check with friends", choose Down and "3 hours", tap "I'm down". Expect, within about 10 seconds each: sheets to Sim friend for Availability, Activity, and Budget, then one or two listing the whole plan (the last includes Your interest). The exact order depends on which phone starts the exchange. Tap Send on each. Expect: a banner "You and Sim friend are both down" with the time (with its date), food, and $15.00; the match in the Down? tab; and the mark moving together and resting as the logo.
26. Developer > Audit log. Expect: new entries to Sim friend starting with psi and ending with accept (for example psi, psi, answer, answer, accept, or psi, query, query, propose, accept, depending on which phone started), with kinds of values only.
27. Down? tab: Withdraw. Developer > Simulated friend: "Sim friend: I'm a maybe". Go down again as in step 22 and send each sheet. Expect: a banner "You and Sim friend are both interested", and Notification Center shows one Starling notification for Sim friend, not two.
28. Withdraw. Developer > Simulated friend: "Sim friend: walk out of range", then go down again. Expect: "No paired friends are reachable right now." and no sheet. Tap "Sim friend: come back in range". Expect: an Availability sheet within 5 seconds. Tap "Don't send", then Withdraw. Expect: the mark goes straight to apart, no notification.
29. Go down with "free yesterday at noon". Expect: the review stays open with "Your rules leave no free half-hour before this ends. Change the times or pick a later end." Nothing is sent.
30. Go down with "free tonight", turn on "Never share time" in the review. Expect: a warning that Down can't check with anyone. Turn on "Never share activity" instead. Expect: a warning that each friend's check ends without a match.

## Wi-Fi Aware (two iPhones 12 or later, capability enabled for the App ID)

Run lane E2's checklist (`docs/checklists/phase-1-E2.md`) from Developer > Wi-Fi Aware on both phones: its "make discoverable" and "find" buttons are "Let a friend find this phone" and "Find a friend's phone", and the paired-devices list is on the same screen. The links section now shows only Starling friends with a live secure session, so pair in Starling (steps 11 and 12) before its link steps. Then:

31. Developer > Wi-Fi Aware: tap "Round trip" next to your friend 5 times. Expect: a time each, under 200 ms.
32. Developer > Audit log. Expect: one "hello" entry per round trip you started and per reply you sent, with no values.

## Release build

33. In Xcode, Product > Scheme > Edit Scheme > Run > Build Configuration: Release. Run. Expect: Down? says "isn't in this build yet"; Friends is real (no Sim friend) and pairs with another phone as in steps 11 and 12; Developer shows Model Bench, Wi-Fi Aware, Audit log, and "Release (no fakes)", with no Nearby, Fakes, or Simulated friend section. Set it back to Debug.
