# Device checklist: Phase 1.5 lane A (Shell and IA)

Two iPhones on iOS 27 with this branch's Debug build. Delete Starling from both first so first-run behavior shows. Find a time (lane C) and Pick a place (lane D) are the real skills; their own checklists (`phase-1.5-P15-C.md`, `phase-1.5-P15-D.md`) cover them in depth, and the steps below cover how the app wires them. Down for… (lane B) runs its real service in Debug, on the insecure PSI stub only Debug has; its checklist covers it in depth. Steps 9 to 15 and 27 walk the shell on one phone: turn on You › Developer › "Scripted Down for… (next launch)" and relaunch first, and a request then gets a proposal after about two seconds, made from your own chips. Turn it off again for the Down for… steps that use both phones.

## First launch, nothing asked

1. Phone A: open Starling. Expect: Home, "Nothing in progress", no system alert of any kind, tab bar with Home, Friends, You, and a separate round New (+) button.
2. Phone A: switch the phone to Dark Mode. Expect: every tab readable, the status mark in the dark tokens.
3. Phone A: tap You. Expect: Your agent "Runs on this iPhone", Privacy with Place, Budget, Diet, People (Share / Ask me / Never), the line "Time and activity are always shared as the overlap. Nothing can line up without them.", Skills with Down for… "No permissions needed", Find a time "Calendar · reads busy and free only" and a Use my calendar / Just ask me switch, Pick a place "Location · asks when you use it", no Swap photos, then Your rules, then Developer at the very bottom.

## Pairing, nickname hygiene, Local Network at first Pair

4. Phone A: Friends › Add friend. Expect: the Local Network alert now, not before. Allow.
5. Both phones: pair through the Wi-Fi Aware picker. Phone A, after picking Phone B: Expect: the name field is empty, with a button "Use "<Phone B's name>", the name that phone gave itself". Type "Maya".
6. Both: compare codes, confirm. Expect: Maya in Friends with a colored pair symbol; the same symbol every time Maya appears.
7. Phone A: Add friend again and type "maya" (or "Mауa" with a Cyrillic а) for a second pairing. Expect: an orange "You already call another friend Maya" (or "This looks like Maya") warning and the button reads "Pair anyway". Cancel.
8. Phone A: Friends › Maya. Expect: "What their Starling does" lists Down for…, Find a time, Pick a place as Yes once Phone B has said hello; Close friend switch; Link to a contact; History "Nothing yet".

## New, Home, and It's a plan (scripted Down for…, one phone)

9. Phone A: tap New, type "boba tonight with whoever's free". Expect within 2 seconds: "Starling understood" with a filled "Down for boba" chip, then "Tonight after 7 PM" (or the current hour), "Ask quietly", and "Open for 3 hrs", all shown as applied; "boba" appears on no other chip; Ask on All friends with Maya's symbol; the button "See who's up for it"; under it "If nobody's up for it, nobody sees you asked."
10. Phone A: tap the "Down for boba" chip, change it to "movie night", Done. Expect: "Down for movie night", and no remove control on it. Tap the time chip, move the start an hour later, Done. Expect: the chip shows the new time. Tap its remove control. Expect: the time chip is gone. Tap "Open for 3 hrs". Expect: a menu titled "How long friends can answer" with "1 hour", "3 hours", "Until tonight"; choose Until tonight. Expect: "Open until tonight". Tap Edit. Expect: the full details sheet still opens.
11. Phone A: tap Cancel. Expect: back on the tab you came from; reopen New: the draft is empty.
12. Phone A: type "boba tonight" again and tap See who's up for it. Expect: a consent sheet over everything listing what leaves the phone, Maya's symbol at top left; Send. Then "Want a heads-up when friends are up for it?": tap Turn on, then allow the system alert.
13. Phone A: Home. Expect: "Your agent is working on 1 thing", then within about 2 seconds a Needs you card "You and Maya are both down for boba" with I'm in / Not tonight and "If you pass, they just won't see it."
14. Phone A: lock the phone before step 13's card appears. Expect: one notification titled "Down for boba" with the card's sentence; no notification for anything else.
15. Phone A: tap I'm in. Expect: It's a plan opens with the lit logo, "You both said yes", the plan card, Keep it going: Add to Calendar "No permission needed", Somewhere else? (Pick a place), Message the group.

## Hand-offs

16. Phone A: Add to Calendar › Add. Expect: the system event editor pre-filled with "Boba with Maya" and tonight's time; no calendar permission alert. Tap Add. Expect: the event in Calendar.
17. Phone A: Message the group. Expect: "Who's who" offering "Link Maya to a contact", with the line that the link stays on this phone. Link a contact, tap Open Messages. Expect: Messages with that contact's number and "It's a plan: boba, tonight at ...". No Contacts permission alert.
18. Phone A: Done, then Home › Coming up › the plan. Expect: plan detail with Message group, "How this came together" showing Down for… "Both down for boba" and Calendar "Added to your calendar", and "What left your phone" with Shared and Kept on your phone rows.
19. Phone A: say "Hey Siri, what's my next plan in Starling". Expect: "Boba with Maya, tonight at ..." Then lock Phone A and ask again. Expect: Siri asks you to unlock first and says nothing about the plan until you do.

## Chaining and permissions just in time

20. Phone A: from the plan, Somewhere else? Expect: New on Pick a place, only the plan's people asked, a line naming what this step also shares.
21. Phone A: turn on Near me, tap Find places. Expect: Starling's own location sheet first (lane D's title and three rows, one Continue button, no Cancel); Continue. Expect: the real system location alert with lane D's purpose string. Allow. Expect: a few places listed with switches; pick two and send.
22. Phone B: answer with I'm in on a place; Phone A: I'm in. Expect: the parent plan's card and plan detail now show that place, and "How this came together" lists Pick a place under the plan.
23. Phone A: New › Find a time, type "find a time tomorrow", start it. Expect: Starling's calendar sheet ("Find a time works best with your calendar", Your agent reads / Never leaves your phone / "Maya sees: Only a few times you're free", one Continue), no Ask quietly choice. Continue. Expect: the real system calendar alert, saying "Starling checks when you're busy so friends' agents can find a time without asking you. Event details stay on your iPhone." Tap Don't Allow. Expect: "No problem, your agent will ask you instead.", the request still goes out, and You shows Find a time set to Just ask me. New shows no "Open for" chip: a Find a time request stays open until the time it asks about starts (at least a day, at most a week). The time chip can be edited but has no remove control.
24. Phone B (calendar never asked): receive step 23's request. Expect: no Starling sheet and no system calendar alert (a friend's request never asks for a permission), and "Phone A's agent asked when you're free" under Needs you.

## Privacy topics and skill switches

25. Phone A: You › Privacy › Place: Never. Then New › Pick a place tile. Expect: the tile reads "Pick a place needs Place. You set Place to Never." and cannot start.
26. Phone A: You › Skills › Find a time off. Expect: its tile reads "Turned off in You". Phone B (Friends › Phone A) after the next hello: Find a time "Doesn't do this yet". Phone B: start Find a time with Phone A anyway (from an older card). Expect: nothing at all on Phone A.

## A friend's side (Developer)

27. Phone A: Developer › "Maya is down for tacos too". Expect: a Needs you card "You and Maya are both down for tacos"; tap Not tonight. Expect: it leaves Home; Friends › Maya › History shows "You passed".

## What left your phone

28. Phone A: open a plan made with Find a time, then What left your phone. Expect: Shared lists the time first, then any other topic, each once; Kept on your phone lists Calendar details.
29. Phone A: start Down for…, and while the consent sheet is up, swipe Starling away; reopen and open that request's plan detail once it is a plan. Expect: no claim that something stayed on the phone it cannot confirm (a line saying it can't confirm everything, or no Kept list).

## Core v2.1: modes, audience, topics

30. Phone A: New, type "boba tonight". Expect: an Ask quietly / Ask directly choice under Ask, Ask quietly selected, the line "Friends see nothing unless they're up for it too.", and under the button "If nobody's up for it, nobody sees you asked." Switch to Ask directly (or tap the "Ask quietly" chip). Expect: the chip reads "Ask directly", the line "Friends see that you asked and can say yes or pass.", and under the button "The friends you ask see that you asked." Find a time and Pick a place show no mode chip.
31. Phone A: Friends › New group "Climbing" with Maya, Save. New › Ask menu. Expect: All friends, Close friends, Climbing, Everyone except…, Pick friends. Choose Everyone except…, tap Maya. Expect: Maya dimmed, a chip "Not Maya", and the line that nobody you leave out can tell.
32. Phone A: Friends › Maya › When you ask friends: Only ask quietly. New › All friends with Ask directly. Expect: Maya dimmed (not asked); switch to Ask quietly: Maya asked again.
33. Phone B (Maya), during steps 31 and 32: Expect nothing at all on Phone B for any request it was left out of: no notification, no card, nothing in Home.
34. Phone A: You › Privacy. Expect: Place, Exact location, Budget (Never), Diet, People, Photos, Interests (Share), Calendar details (Never), each with a line explaining the selected choice; Calendar details set to Share says Share and Ask me aren't used by any skill yet.
35. Phone A: quit Starling while a consent sheet is up, then reopen. Expect: no sheet, and the request back in progress, not ended.

## Release build

36. Archive a Release build (or run the Release scheme). Expect: You has no Developer section, and nothing anywhere says "test build"; New's Down for… tile says "Not in this build yet" (no private PSI provider yet, ADR 0144), while Find a time and Pick a place start, and typing "find a time tomorrow" routes to Find a time (the on-device model). No Swap photos anywhere (its flag is off).

## Down for… with both phones (real service, Debug)

37. Phone A, scripted Down for… off, with Maya and Jake paired: New, "boba tonight with everyone except Jake". Expect: Ask shows Everyone except… with Jake left out, never Jake alone.
38. Phone A: "boba tonight" to Maya and Jake, Ask quietly, send. Expect: Home's In progress shows one row "Checking with 2 friends". Phones B (Maya) and C (Jake): each send their own "boba tonight" to Phone A, Ask quietly (neither sees Phone A's ask before that). Expect on Phone A: two separate cards, "You and Maya are both down for boba." and "You and Jake are both down for boba.", each with its own I'm in.
39. Phone A: I'm in on both. Expect: two plans under Coming up and a row "Invite Maya and Jake together". Tap it. Expect: New on Down for… with Ask directly, Maya and Jake and the plan's activity and time; send. Expect: the row is gone.
40. Phone A: on a new quiet ask's card, tap Not tonight. Expect: the card leaves Home at once; Phone B sees nothing change until the card's window ends (about 15 minutes), then nothing at all.
