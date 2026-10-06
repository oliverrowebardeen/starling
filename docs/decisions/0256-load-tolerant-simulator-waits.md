# ADR 0256: Separate protocol time from simulator scheduling

- Status: Accepted (code merged on main; status updated 2026-10-06)
- Date: 2026-10-02
- Owner: P15-F

## Context

The unchanged chaining roster and app location-denial tests hit their five-second
condition limits in the gates for PRs #90 and #91 on a heavily loaded host. Increasing
only those two limits would leave the other Phase 1.5 waits, real owner windows,
and bounded wall-time transcript assertions exposed to the same scheduling load.

## Decision

1. Route Phase15RedTeamTests condition and authenticated-mesh waits through one
   helper with a 60-second SuspendingClock budget. Evaluate the condition before
   declaring a timeout, including after a delayed wake. Preserve cancellation
   and predicate errors. Inherit the caller's actor isolation so app predicates
   remain on MainActor. A false condition at the deadline still fails the test.
2. Inject the existing test clock into DownForService, FindATimeService, and
   PickAPlaceService in the app fixture. Down for service-only tests also use
   virtual time for every timer. Wait for the service to register the expected
   deadlines before advancing time. The app's owner-driven flows retain the
   normal 15-minute Down for owner window. Drive retries on both phones, below
   their owner windows, when replies cross either sender's bookkeeping.
3. Amend ADR 0254 decisions 4 and 5: compare proposal counts and terms at exact
   virtual delivery deadlines, without sub-second host-time tolerances. Check
   all five scheduled sends in the prefix comparison fixture, and all four
   sends in the held-send regression. The owner window advances only after
   those assertions. The held third send still crosses the fourth's deadline.
4. Wait for actual app support cards instead of a fixed bootstrap sleep. Wait
   for invitee confirmation and armed virtual deadlines before the place roster
   tests advance time. Consent fixtures that do not test expiry allow 180 seconds
   for the sheet; suite watchdogs allow five minutes, beyond a condition wait.
   Journal recovery checks resolution of the interrupted message, since restored
   services may already be journaling new sends.
5. Verify the complete Simulator package with at most four explicitly tracked
   CPU workers. Stop and reap only those processes. Run the normal local gate
   separately. This changes test fixtures only; production timers are unchanged.

## Limits

SuspendingClock excludes system sleep, not CPU contention. The larger budget
accommodates host scheduling; these tests do not establish device performance
or radio timing. Existing device checks remain in
`docs/checklists/phase-1.5-P15-F.md`, particularly items 19 and 20. This host-only
follow-up adds no device steps. The legacy Phase 1 tests are unchanged.

## Sources

- [Swift SE-0329: Clock, Instant, and Duration](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0329-clock-instant-duration.md),
  checked 2026-10-02, for SuspendingClock and cancellable clock sleeps.
- Installed Xcode SDK `_Concurrency.swiftmodule/arm64e-apple-macos.swiftinterface`,
  checked 2026-10-02: SuspendingClock conforms to Clock; Clock supplies
  `sleep(for:tolerance:)`; isolated parameters preserve the caller's actor.
- ADRs 0253 to 0255 and the Orchestrator's PR #90/#91 load-failure report.
- `Packages/Skills/DownFor/Tests/DownForTests/DeliveryScheduleTests.swift` and
  `Harness.swift` at `1f8ed56`, for the service's injected timer contract.
