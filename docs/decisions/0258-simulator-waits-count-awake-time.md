# ADR 0258: Simulator waits count awake time

- Status: Accepted (code merged on main; status updated 2026-10-06)
- Date: 2026-10-03
- Owner: P15-F

## Context

The host machine went to sleep during some local gate runs, and the Orchestrator
asked for every Simulator harness wait to exclude that time, preserving its
existing bound.
Lane B's PR #110 documents the sleep-related failure of its native test.

At baseline `78963ab`, P15.eventually and appEventually already use a 120-second
SuspendingClock wait, from ADRs 0256 and 0257. Changing that clock again cannot
explain the two reported real-service timeouts. Their exact failing gate commits
were requested. This change does not claim to reproduce those historical runs.

Older Simulator tests and scenarios still use Simulation.eventually and its
mesh helper. Those use ContinuousClock in SimulatorKit, outside F's ownership.
The legacy Down test clock and observation window also use default Task sleeps.

## Decision

1. Put AwakeWait in F's Scenarios directory. All owned scenario and test
   condition waits use its SuspendingClock implementation. It checks cancellation
   and the condition before deciding that the deadline has expired, and preserves
   predicate errors and the caller's actor isolation.
2. Preserve the bounds and polling intervals: legacy callers keep five seconds
   with 5 ms polls; P15 and its app wrapper keep 120 seconds with 10 ms polls.
   Mesh waits use the same bounds as their callers. The two test targets that
   did not depend on Scenarios gain only that test dependency.
3. The legacy Down injected clock, its one-second silence observation interval,
   the app consent auto-approver's 5 ms polling interval, and transcript timestamps
   use SuspendingClock explicitly. Protocol retry intervals, injected virtual
   deadlines, consent timeouts, and suite watchdog bounds do not change.
4. The fixed-sleep sweep found no remaining positive assertion that depends on
   an arbitrary sleep in Tests. Legacy waitForTimeouts remains a bounded negative
   observation window, now on awake time, not proof that asynchronous work has
   drained. The Phase 1.5 tests retain their condition and queue barriers.
5. The first full run still timed out in the place exclusion/silence deadline
   case on SuspendingClock. That fixture advanced the organizer's virtual time
   after observing only the friend's send. Wait for the organizer to handle
   that exact authenticated answer before advancing its answer window. This
   removes a test scheduling race without changing the protocol deadline or
   bypassing the service's correlation checks. Likewise, both shortened-roster
   deadline cases wait for the organizer to handle the included friend's
   acceptance before moving virtual time. It does not claim to fix #105.

## Verification and limits

Run both reported cases and Tools/test-all.sh Tools/Simulator, then run the
local gate once for this branch. Check that no owned test/scenario calls the
ContinuousClock-based Simulation wait helpers or default Task.sleep anymore.
SimulatorKit's public wait API is unchanged; this does not fix callers outside
the owned scenario/test paths. SuspendingClock still counts awake CPU contention.
No test forces the host to sleep, and no device behavior changes.

Existing device checklist docs/checklists/phase-1.5-P15-F.md items 3, 19, and 20
remain applicable. No new phone steps are needed for a host harness change.
PR #107 and the pending Change the plan coverage remain separate.

## Sources

- [Swift SE-0329, SuspendingClock](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0329-clock-instant-duration.md#suspendingclock),
  read 2026-10-03: its clock does not advance during machine sleep.
- PR #110,
  read 2026-10-03: native Down test evidence and virtual-time fixes.
- ADRs 0256 and 0257; SimulatorKit/Simulation.swift and the test harnesses at
  `78963ab`, read 2026-10-03.
