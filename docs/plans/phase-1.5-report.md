# Phase 1.5 report: from a Down app to an agent interaction platform

- Date: 2026-10-01
- Owner: Orchestrator
- Status: code complete and merged (main `7ed01cb`); the exit criteria still need Oliver's run on two iPhones

## Summary

Starling is now a platform of skills.

- **Skills on one lifecycle.** Down for…, Find a time, and Pick a place share one lifecycle, one consent path, one shared ledger, and one audit. Swap photos proves the time-triggered chain behind a flag.
- **The app.** It has the Home, New, Friends, and You shell, and every skill is wired into it.
- **Owner changes mid-run.** Two landed as Core v2.1:
  - Never keeps a value on the phone (ADR 0019);
  - send modes and audience, with exclusion that cannot be detected (ADR 0020).

Adversarial review drove most of the late work:

- **Lane PRs:** every one went through two to five review rounds.
- **Fixes in Core:** fixes that several lanes needed went into Core once, as ADR 0021's conversation ledger, pre-send audit hook, per-friend numbering, and cancellation.
- **Red team:** lane F's suite runs 119 adversarial tests against the real services. It filed twelve defects (#63 to #68, #76, #79 to #81, #84). All twelve are fixed and merged, with F's reproductions kept as regressions, and the suite ends with zero known issues.

## Exit criteria

The prompt's section 12 is run on two real iPhones. "Ready for device" means the code, its tests, and the lane's device checklist (`docs/checklists/phase-1.5-*.md`) are merged. Only Oliver's run closes a criterion.

| # | Criterion | Status |
|---|---|---|
| 1 | "boba tonight with whoever's free" in New routes to Down for… with editable chips | Ready for device. Measured on macOS 26.7: routing 36/40 (held-out 19/20), chips 20/23 (held-out 6/12), send mode 23/23 (held-out 12/12). ADR 0016 needs a re-measure on the iOS 27 model on a device. |
| 2 | Two phones down for overlapping times; proposal under Needs you; both confirm; It's a plan | Ready for device, in a Debug build (see Known limits). |
| 3 | Add to Calendar with no permission prompt | Ready for device (ADRs 0018, 0204). |
| 4 | Chaining to Pick a place, recorded on the timeline; What left your phone lists exactly what was shared | Ready for device (ADRs 0240, 0241, 0021). |
| 5 | Find a time shows Starling's sheet before the system prompt; denial falls back to ask-owner | Ready for device (ADRs 0013 amendment 6, 0220 to 0222). |
| 6 | A topic set to Never is respected by every skill; a required one explains why | Ready for device. Never now means "stays on the phone" (ADR 0019), enforced by the policy and the ledger. |
| 7 | No dating-app tone; no Down screen without an activity | Ready for device, checked by eye (ADR 0017). |
| 8 | A peer without a skill sees a graceful message; unsupported chains are hidden | Ready for device (ADRs 0010, 0012). |
| 9 | Red-team scenarios pass | Done in code: 119 tests, zero known issues (ADRs 0250 to 0255). |
| 10 | Release builds contain no Developer tab or test-build notices | Done: enforced on every gate and in CI (#62). |

## Where reality contradicted the prompt

1. **No DESIGN.md existed.** The Orchestrator wrote one from the mockups (#44).
2. **Copy.** The mockups said "match". Oliver clarified that the goal is tone, not a word list (ADR 0017).
3. **No action-button tab.** New uses iOS 27's prominent tab (ADR 0015).
4. **Pre-permission screens.** The HIG wants one "Continue" button before a system alert, not two choices (ADR 0013).
5. **Messages.** It needs phone numbers, and Starling has none by design, so Message the group uses an optional local contact link (ADR 0018).
6. **A2A skills have no version field.** Starling versions skills itself (ADR 0010).
7. **A new on-device model in iOS 27.** The quality numbers so far are from macOS 26.7 (ADR 0016).
8. **"Priya sees only times you're both free" holds only for the friend who answers.** The starter names some free times first (ADR 0013 amendment 6).
9. **A quiet group reveal across different audiences leaked,** round after round, through rosters, coupled schedules, and candidate caps.
   - Quiet asks are now one-to-one, each match its own card with its exact time.
   - A group plan is an explicit Invite from the starter, with the roster under the people topic (ADR 0011 amendment 17, ADR 0210).
   - The mockup's "All 3 of you said yes" is reached through that invite.
10. **Silent noes.** Every no in Find a time is silent, so a starter whose friends all decline waits for the 30-minute deadline (ADR 0221).
11. **Envelope versions.** Envelope version 1 could not carry a send mode safely, so version 2 retired it (ADR 0020).
12. **Hosted CI did not run for most of the phase.** Every merge went through the local gate (ADR 0007).

## Decisions made during the run

- **Orchestrator ADRs:**
  - 0019, 0020, 0021 (amendments 7 to 13);
  - 0011 amendments 13 to 17;
  - 0013 amendment 6;
  - 0019 amendment 10.
- **Lane ADRs:**
  - lane A: 0200 to 0206;
  - lane B: 0210 to 0212;
  - lane C: 0220 to 0222;
  - lane D: 0230 to 0232;
  - lane E: 0240 to 0242;
  - lane F: 0250 to 0255.

  All are Proposed, except lane F's test-only ADRs 0250 to 0252.

## Known limits and open issues

- **Down for… runs in Debug builds only** until a private set-intersection provider exists outside `StarlingFakes` (ADRs 0144, 0206). Device checks use Debug builds, so they are not blocked. Shipping Down for… in Release is.
- **Accepted limit (ADR 0021 decision 11).** A cancelled send's sequence number is not taken back in the store. If the app relaunches with its clock moved back, a friend can see a one-number gap.
- **Open issues:**
  - #46: roster presentation on consent sheets;
  - #9: the model's negative-control matches (Phase 1 carry-over);
  - #59: a flaky Wi-Fi Aware transport test under load.
- **Deferred:**
  - a private group reveal (needs its own design and review);
  - per-skill state on `Interaction` (lane C's request 7);
  - the threat model additions the lanes asked for in `docs/requests/P15-*.md`.

## Needs Oliver

1. **Device run.**
   - Enable the Wi-Fi Aware capability for `com.oliverrowebardeen.starling`, and sign back into Xcode, so a Debug build can be installed and paired on two iPhones.
   - Then run the checklists in `docs/checklists/phase-1.5-*.md`.
2. **Re-enable hosted CI.**
3. **What are Muse and Dots?** Still open from ADR 0018.
4. **Queued next** (`docs/plans/phase-1.5-lane-plan.md` section 5):
   - the pairing-methods lane;
   - onboarding and personalization.

   Planning starts with that section's "To settle" list.
