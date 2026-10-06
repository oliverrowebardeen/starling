# ADR 0257: Observe service completion in red-team tests

- Status: Accepted (code merged on main; status updated 2026-10-06)
- Date: 2026-10-02
- Owner: P15-F

## Context

After PR #93, the Orchestrator reported another timeout waiting for the place
proposal in the chaining roster test. At baseline `83329f3` that call already
uses ADR 0256's 60-second SuspendingClock helper. Twenty unchanged chaining
suite runs with four CPU workers passed locally, so this does not claim to
have reproduced the exact reported scheduling interleaving.

The fixture still had two avoidable assumptions. It froze the organizer's
retry clock while waiting for proposals, so an unanswered exchange could not
retry regardless of the host wait budget. Elsewhere, fixed 75 to 350 ms sleeps
stood in for service work and event consumers finishing. Removing those sleeps
exposed early assertions on invitee events and retirement before restart.

## Decision

1. Give Phase15RedTeamTests condition waits 120 seconds on SuspendingClock,
   keeping the condition check before the timeout check. False conditions,
   predicate errors, and cancellation still fail. Polling intervals are not
   success criteria.
2. The chaining roster test explicitly drives the organizer's registered
   virtual retries while awaiting proposed, stopping short of the answer
   window. Its later confirmation uses the deadline persisted by the actual
   service, since retries may have advanced virtual time. Both ordinary
   delivery and an intentionally lost first answer must reach the same
   shortened roster and next-chain audience.
   The equivalent place pass/silence test uses that same deadline handling.
   App place flows may drive five virtual minutes of retries within their
   normal 15-minute answer window; other app skills retain one minute, and
   the calendar-denial flow explicitly drives its pending delivery retries.
3. A relay's `handle` return proves only that the service accepted that call.
   Work the service spawned needs a separate condition. Wait for actual photo
   invitee events, failed-admission retirement, consent cancellation, and the
   app's failed terminal state. Observe the exact newer time proposal instead
   of accepting the old card's identical lifecycle state.
4. Down for has a queue per friend. After an authenticated test input, send a
   fresh, already-retired conversation's sentinel through Outbox and Inbox.
   Its ledger read proves the friend's preceding queue work completed. It
   cannot open a request or produce a response. These fixture-only sentinels
   use separate conversations and are not part of the request transcript.
5. Remove fixed scheduling allowances in the Phase 1.5 target. Negative checks
   follow the applicable delivery/queue boundary; positive controls wait for
   the resulting state or message. Protocol boundary assertions wait for
   registered virtual deadlines, not wall time. The app consent auto-approver
   retains a cancellable polling loop; its interval decides no assertion.

## Limits and verification

This changes test scheduling only. It does not establish the cause of the
Orchestrator's particular timeout or measure device performance. In particular,
returning from a policy evaluation alone is not proof that every later actor
has processed its result. Existing final-state and superseded-proposal checks
remain necessary. Native service suites complement these integration checks.

The sweep is scoped to Phase15RedTeamTests, the suite introduced by this lane.
Legacy Phase 1 simulation/negotiation timers remain separate from this follow-up.
Run the complete Simulator package under at most four owned CPU workers, then
the complete local gate. No new device behavior is introduced; checklist
`docs/checklists/phase-1.5-P15-F.md` items 3, 18, and 19 remain applicable.

## Sources

- ADR 0256, including its checked Swift clock documentation and SDK contract.
- `PickAPlaceService+Organizer.swift`: query/proposal retry loops and persisted
  confirmation deadlines, read at `83329f3`.
- `DownForService+Plumbing.swift` and `DownForService+Steps.swift`: per-friend
  serial work and retirement before receipt processing, read at `83329f3`.
- Orchestrator's follow-up load-failure report, 2026-10-02.
