# Device checklist: Phase 1.5 lane A (Shell and IA)

Two iPhones on iOS 27 with this branch's Debug build. Delete Starling from both first so first-run behavior shows. Until lanes B to D merge, the skills are scripted in Debug builds: a request gets a proposal after about two seconds, made from your own chips (You › Developer says so).

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

## New, Home, and It's a plan (scripted skills)

9. Phone A: tap New, type "boba tonight with whoever's free". Expect within 2 seconds: "Starling understood" with a filled "Down for boba" chip, then "Boba", "Tonight after 7 PM" (or the current hour), "Expires in 3 hrs"; Ask on All friends with Maya's symbol; the button "See who's up for it"; under it "If nobody's up for it, nobody sees you asked."
10. Phone A: tap Edit, delete the time row, Done. Expect: the time chip is gone.
11. Phone A: tap Cancel. Expect: back on the tab you came from; reopen New: the draft is empty.
12. Phone A: type "boba tonight" again and tap See who's up for it. Expect: a consent sheet over everything listing what leaves the phone, Maya's symbol at top left; Send. Then "Want a heads-up when friends are up for it?": tap Turn on, then allow the system alert.
13. Phone A: Home. Expect: "Your agent is working on 1 thing", then within about 2 seconds a Needs you card "You and Maya are both down for boba" with I'm in / Not tonight and "If you pass, they just won't see it."
14. Phone A: lock the phone before step 13's card appears. Expect: one notification with the same sentence; no notification for anything else.
15. Phone A: tap I'm in. Expect: It's a plan opens with the lit logo, "You both said yes", the plan card, Keep it going: Add to Calendar "No permission needed", Somewhere else? (Pick a place), Message the group.

## Hand-offs

16. Phone A: Add to Calendar › Add. Expect: the system event editor pre-filled with "Boba with Maya" and tonight's time; no calendar permission alert. Tap Add. Expect: the event in Calendar.
17. Phone A: Message the group. Expect: "Who's who" offering "Link Maya to a contact", with the line that the link stays on this phone. Link a contact, tap Open Messages. Expect: Messages with that contact's number and "It's a plan: boba, tonight at ...". No Contacts permission alert.
18. Phone A: Done, then Home › Coming up › the plan. Expect: plan detail with Message group, "How this came together" showing Down for… "Both down for boba" and Calendar "Added to your calendar", and "What left your phone" with Shared and Kept on your phone rows.
19. Phone A: say "Hey Siri, what's my next plan in Starling". Expect: "Boba with Maya, tonight at ..." Then lock Phone A and ask again. Expect: Siri asks you to unlock first and says nothing about the plan until you do.

## Chaining and permissions just in time

20. Phone A: from the plan, Somewhere else? Expect: New on Pick a place, Maya picked, a line "This step also shares Diet and may ask for your location."
21. Phone A: tap Suggest places near me. Expect: Starling's own sheet first ("Pick a place can suggest places near you", three rows, one Continue button, no Cancel); Continue. Expect: no real system alert in this Debug build (simulated, see You › Developer); "Nearby" appears as a chip.
22. Phone A: New › tile Find a time, type "find a time next week", start it. Expect: Starling's calendar sheet ("Find a time works best with your calendar", Your agent reads / Never leaves your phone / Maya sees, one Continue). In You › Developer turn on "System alerts say Don't Allow" first to check the fallback: Expect "No problem, your agent will ask you instead." and the request still goes out; You shows Find a time set to Just ask me.

## Privacy topics and skill switches

23. Phone A: You › Privacy › Place: Never. Then New › Pick a place tile. Expect: the tile reads "Pick a place needs Place. You set Place to Never." and cannot start.
24. Phone A: You › Skills › Find a time off. Expect: its tile reads "Turned off in You". Phone B (Friends › Phone A) after the next hello: Find a time "Doesn't do this yet".

## A friend's side (Developer)

25. Phone A: You › Developer › "Maya's agent asks when you're free". Expect: Needs you "Maya's agent asked when you're free" with Review; Review shows three times; pick one, Send my answer. Expect: the card leaves Needs you.
26. Phone A: Developer › "Maya is down for tacos too". Expect: a Needs you card "You and Maya are both down for tacos"; tap Not tonight. Expect: it leaves Home; Friends › Maya › History shows "You passed".

## Release build

27. Archive a Release build (or run the Release scheme). Expect: You has no Developer section, and nothing anywhere says "test build"; New's tiles say "Not in this build yet" until the skill lanes merge.
