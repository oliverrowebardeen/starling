# Phase 1.5 P15-B device checklist: Down for... and the model

Two parts. Part A measures routing and chips on the iOS 27 model, which Apple says changed; it needs one Apple Intelligence iPhone and about 20 minutes. Part B runs Down for... between phones once lane A has wired `DownForService` into the app; it needs two phones (three for B5) and about 15 minutes. Record results at the bottom and send them to the Orchestrator.

## Setup

1. Check out `phase-1.5/b-down-for` (or `main` once merged). `cd Packages/StarlingAgent`.
2. iPhone: iOS 27, Developer Mode on, Apple Intelligence on, cable connected, unlocked.
3. Find the phone's name: `xcrun xctrace list devices`.

## A. Routing and chips on the iOS 27 model

1. Run:
   `TEST_RUNNER_STARLING_MODEL_TESTS=1 xcodebuild test -scheme StarlingAgent-Package -destination 'platform=iOS,name=<iPhone name>' -only-testing:StarlingAgentTests/LiveSkillModelTests`
   Expect: 5 tests run, none skipped, 0 failed calls in each table. The log prints `Variant: core3` or `coreAdvanced3`; note it.
2. In the "Routing accuracy (live)" table, record the **all** row and "Non-requests routed to a skill". On the Mac (macOS 26.7 model) they were 36 / 40 and 2.
3. In "Routing accuracy, held-out (live)", record the **all** row. Mac: see `Packages/StarlingAgent/Reports/phase-1.5-skill-model.md`.
4. In "Down for... chips (live)" and the held-out table, record **all chips** and the wants, place, audience, names, and mode rows. Expect: 0 invented activities (the test fails otherwise). On the Mac, mode was right in every item.
5. Expect "Proposal sentence:" followed by one sentence that names Maya and Jake, says boba, the time, and "Boba Guys". If the log says "Proposal sentence refused", record the reason: the app shows the template sentence instead, which is fine, but it means the phone model is not earning its place there.
6. Decision for New (lane plan risk 1): if routing on the phone is under 80% on either set, or names are under 70%, tell the Orchestrator. New should then lead with the skill tiles, not free text.

## B. Down for... between phones (after lane A wires it)

Phones A and B are paired, both on the Phase 1.5 build.

1. Phone A: tap New, type "boba tonight with whoever's free". Expect: the Down for... tile is chosen within 3 seconds, with chips Boba, Tonight, and All friends. The line under them reads "If nobody's up for it, nobody sees you asked."
2. Phone A: tap "See who's up for it". Phone B: do nothing. Wait one minute. Expect: Phone B shows nothing at all: no notification, no row on Home, no consent sheet. Phone A shows the request under In progress with "Checking with friends".
3. Phone B: tap New, type "down for boba after 8", then "See who's up for it". Expect within 20 seconds, on both phones: a Needs you card such as "You and A are both down for boba. Tonight at 8 PM?" with I'm in and Not tonight. Approve any consent sheet that appears first; the sheet names the other phone's owner.
4. Phone A: tap I'm in. Expect: Phone A's card shows it is waiting; Phone B still shows its card. Phone B: tap I'm in. Expect: "It's a plan" on both phones within 5 seconds, with the same time and activity.
5. Three phones (A, B, C), all down for boba with all friends. Expect: one card on each phone listing all three. A and B tap I'm in; Phone C taps Not tonight. Expect: nothing changes on A or B until the owner window passes (15 minutes by default), then a new card listing only A and B, and no message on either says C passed. Both tap I'm in. Expect: It's a plan for two.
5a. Three phones again, but on Phones B and C pick only A as the audience. Expect: each card lists two people; B never sees C's name and C never sees B's.
6. Phone A: start "pho tonight", then tap the request and withdraw it before Phone B has a request. Expect: it moves to history; Phone B never shows anything.
7. Phone B: switch Down for... off in You, then on Phone A start "boba tonight". Expect: Phone A says B's Starling doesn't do this (if B is the only friend) or leaves B out.
8. Phone A: force-quit Starling while a request is In progress, reopen it. Expect: the request is still In progress, and a plan still forms if Phone B goes down for the same thing.
9. Phone A: type "invite B to tacos friday" in New. Expect: the Down for... chips show Tacos, Friday, B, and the Invite mode. Send it. Phone B, with no request of its own: Expect a card under Needs you within 20 seconds, "A invites you" with tacos and a time. Phone B taps I'm in. Expect: Phone A's card lists A and B; Phone A taps I'm in; It's a plan on both.
10. Phone A: type "boba tonight with everyone except C". Expect: the audience chip shows everyone except C, and Phone C never shows anything, now or when Phone C starts its own boba request.
11. Check every Down for... screen and notification by eye: an activity always follows "Down for", and nothing reads like a dating app (ADR 0017).

## Results

| Item | Device, iOS, variant | Result | Notes |
|------|----------------------|--------|-------|
| A2 routing, tuning (all / non-requests routed) | | | |
| A3 routing, held-out | | | |
| A4 chips, tuning and held-out (all / wants / place / audience / names) | | | |
| A5 proposal sentence | | | |
| B2 silence for a friend not down | | | |
| B3 to B4 two-phone plan | | | |
| B5 three-phone plan and pass | | | |
| B5a rosters only of friends who asked | | | |
| B6 to B8 | | | |
| B9 to B10 invite and everyone except | | | |
| B11 copy | | | |
