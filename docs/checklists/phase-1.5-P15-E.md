# Phase 1.5 P15-E device checklist (chaining and audit)

Run after lane A wires StarlingChaining (requests 4.1 to 4.7 in `docs/requests/P15-E.md`) and lanes B and D land Down for… and Pick a place. Two paired iPhones, A and B, both on the Phase 1.5 build, You › Privacy at defaults. No device was used while building this lane; everything below is untested on hardware.

1. Phone A: tap New, type "boba tonight", send to B. Both tap "I'm in". Expect: It's a plan on both phones, with "Somewhere else?" under Keep it going.
2. Phone A: tap "Somewhere else?". Expect: a sheet naming Diet and your location as new before anything starts. Tap the decline. Expect: no Pick a place request on B, and the row still there.
3. Phone A: tap "Somewhere else?" again and approve. Expect: B shows a Pick a place request under Needs you within 5 seconds, and nothing starts on B until B taps.
4. Both phones: agree on a place. Expect: the plan card shows the new place; Phone A's Keep it going still offers "Somewhere else?", and tapping it now starts without the extra sheet.
5. Phone A: open the plan. Expect: How this came together lists Down for…, then Pick a place, with times; What left your phone lists boba, the time, and the place under Shared, and Budget and your exact location under Kept on your phone.
6. Phone A: compare What left your phone with each consent sheet you approved in steps 1 to 4. Expect: nothing listed that no sheet showed, and nothing a sheet showed missing.
7. Phone B: open the same plan. Expect: Pick a place appears on the timeline marked as A's request.
8. Phone B: switch Pick a place off in You › Skills, then Phone A opens the plan. Expect: "Somewhere else?" is gone on A after B's card refreshes, not shown and then failing.
9. Debug build with Swap photos switched on, both phones: make a plan ending in 3 minutes. Phone A: turn on "Swap photos after" and approve the sheet naming Photos and photo access. Phone B: leave it off. Expect: no photo prompt on either phone.
10. Wait for the plan to end with Starling open on A. Expect: within a minute, A asks you to pick photos, with no system photo access alert. Pick 2. Expect: B shows "2 photos" under Needs you; B gets no picker and no alert.
11. Repeat step 9 without turning "Swap photos after" on. Expect: nothing happens on either phone when the plan ends.
12. Release build: open It's a plan. Expect: no Swap photos row anywhere.
