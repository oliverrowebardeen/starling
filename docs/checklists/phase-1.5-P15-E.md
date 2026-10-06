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

Change the plan (ADR 0022, ADR 0243), three phones A, B, and C in one plan:

13. Phone A: open the plan, tap Suggest a change, pick 9:00. Expect: B and C each show "A suggests 9:00 instead"; nothing changes yet on any phone.
14. B and C: tap Sounds good. Expect: within 5 seconds the plan reads 9:00 on all three phones, and A's timeline lists the change.
15. Phone A: suggest dinner instead. B: Sounds good. C: Keep it as is. Wait for the window to close. Expect: A reads "The plan stays as it was" with nobody named; B's card just closes; the plan is still boba on all three.
16. Phone B: while A's suggestion is open, look for Suggest a change. Expect: it is not offered until A's suggestion settles.
17. Phone A: suggest adding D, a friend of A's. B and C: Sounds good. Expect: D gets an invite showing the plan and who is in it; after D accepts, all four phones list four people.
18. Phone C: Leave this plan. Expect: no sheet; C's plan ends; A and B (and D) show C left and list one fewer person.
19. Phone A: suggest 9:30. Phone B: tap Sounds good, then turn on Airplane Mode before C answers. C: Sounds good. Wait 2 minutes, then turn B's Airplane Mode off. Expect: within 5 minutes B's plan reads 9:30, and B's card shows it planned, not closed.
20. Phone A: suggest 10:00. B and C: Sounds good. Force-quit Starling on B right after C taps, then reopen it. Expect: B's plan reads 10:00 within 5 minutes of reopening, with one entry for the change on B's timeline.
21. Phone A: suggest dinner. B and C: Sounds good. On A, tap Withdraw as fast as possible after C taps. Expect: either the plan changes on all three phones or on none; never on A alone.
22. Phone A: tap Somewhere else?, and while the place step is open, add D through Suggest a change (step 17). Then finish the place step without D. Expect: D stays in the plan on every phone; the place step changes nothing it was not asked over.
23. Four phones A, B, C, and D in one plan. Phone B: suggest 9:00. A, C, and D: Sounds good. Turn on Airplane Mode on D right after D taps. Phone C: Leave this plan. Wait 1 minute, then turn D's Airplane Mode off. Expect: within 5 minutes A, B, and D all read 9:00 and list A, B, and D; C's plan has ended.
24. Phone A: suggest 9:30. B: Sounds good. Force-quit Starling on A before C answers, and leave it closed. Expect: 15 minutes after A's window closes, B can suggest a change again (no "another change is in progress").
25. Phone A: suggest dinner. B and C: Sounds good. Force-quit Starling on A right after C taps, then reopen it. Expect: within 5 minutes either all three plans read dinner, or none do and A reads "The plan stays as it was" while B's and C's cards close.
26. Phone C: Leave this plan, and force-quit Starling on C within a second. Reopen it. Expect: C's plan shows ended at once; A and B list one fewer person within 5 minutes.
27. Five phones: A, B, C, and D in one plan, and E, a friend of B's. Phone B: suggest adding E. A, C, and D: Sounds good. Turn on Airplane Mode on C right after C taps. E: accept the invite. Phone C: Leave this plan, then turn Airplane Mode off. Expect: within 5 minutes A, B, D, and E all list A, B, D, and E, and E's timeline shows C left.
