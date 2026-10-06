# ADR 0259: Authenticated plan-change regression boundaries

- Status: Proposed
- Date: 2026-10-03
- Owner: P15-F
- Builds on: ADRs 0022, 0243, 0253, 0254, 0257, 0258

## Decision

Exercise the real ChangePlanService and ChainPlanner merged by PR #111.
Simulation's secure channel and sole Inbox establish the sender. Requests and
attacks use Outbox, with deterministic policy and consent; a malicious peer
may replace its own outgoing ledger, but cannot replace the receiver's ledger.
The event adapter applies real Interaction events and records invalid ones.
It is explicitly a stand-in for the app coordinator, whose coverage follows A.

Each seeded phone has a distinct local Plan ID and a shared origin. Two cases
also form the parent through real Down for Invite and Find a time before an
original invitee starts the change. The whole offered roster, revision, local
identity, origin, unrelated terms and later recipients are checked where the
case concerns them. A successful field update alone does not prove unanimity.

Delivery-loss tests drop an authenticated envelope after Inbox and before
service delivery. They retain the envelope for inspection. Repeating one at
that boundary tests service idempotence, not secure-channel replay rejection.
Stranger messages travel through a stranger's own authenticated connection.
An absolute injected clock controls protocol windows and resends; timers must
be registered before advancing to their retry. P15's SuspendingClock only
bounds host condition waits. No load, physical sleep or phone is required.

Negative assertions follow an awaited handle, an observable journal/ledger
boundary, or a finished and drained service event stream. Closing that stream
is an observation barrier, not a restart or radio-recovery claim. Restart cases
retain the interaction store and journals while replacing the real service;
actual disk recovery and coordinator write serialization remain A's coverage.

PC35 holds commit publications before the stand-in coordinator persists them,
then discards those old-process events on service replacement. It requires a
retained confirming/applied journal record and verifies the older persisted
parent before crashing. This tests recovery across that publication gap, not
a disk power-loss claim. PC36 selects the new live root after a rejoin, keeping
the withdrawn original as history, just as the service's lookup does.
PC37/PC38 prepare next-revision proposal plans and separately publish their
place/attendees artifacts to the real ChainPlanner updater. They isolate stale
basis and event ordering, without claiming coverage of D's producer or A's
actual coordinator. Both include valid fresh-result/order controls.

Keep the expected invariant even when a service fails it. File the precise
reproduction and wrap only its failing assertions with the issue number.
The setup, positive controls, authentication, timer conditions and unrelated
assertions remain ordinary failures. A wrapper must be removed when the owner
fixes the finding; an unexpected pass is not silently accepted.

## Evidence and limits

After #111 merged, rebase F's commits onto main `7e285f5`. The complete
`Tools/test-all.sh Tools/Simulator` run passes 218 tests, including 167 Phase
1.5 tests in 33 suites, with zero warnings or known issues. The original 42
added tests and the three new test functions pass. All former #113, #114,
#116, #117, and #119 findings use ordinary assertions.

PC04/PC32 keep an accepted offer unchanged and send no acknowledgment after a
forged confirmation; only the genuine confirmation produces an applied receipt.
PC08 inspects withdrawals across fresh conversations at the same virtual
answer deadline. Both decline and silence acknowledge them with no values;
the decline itself sends nothing in the original conversation. PC18 likewise
checks the acknowledgment of a withdrawal whose offer was lost. PC19 now fails
only confirmation-record writes, after the newly required opening journal
writes, so it still tests the commit boundary. The harness supplies a fresh
PlanChangeHolds to each replacement service.

PC39 forces both arrival orders of a leave and a committed confirmation, with
and without an added friend. Every remaining phone reaches revision 2 with the
same roster and fields, then a further change reaches revision 3. PC40 loses
the value-free departure forwarded to the added friend, checking its digest
and retained delivery, then recovers by retry or suggester replacement. PC41
loses a withdrawal or its acknowledgment, with and without replacement. Each
retry names the same offer in a fresh conversation, settles the retained
withdrawal, and leaves the parent unchanged. These three test functions have
ten parameterized cases.

Earlier isolated-merge failures are recorded in the issues and previous request
log revisions. They are superseded by the passing main run, including the
existing app/place integration tests. No host bound or protocol deadline
increased. Exact evidence and remaining matrix subcases are in
`docs/requests/P15-F.md`; device steps 23 to 38 remain unrun.

The requested ack/resend behavior is an invariant, not a best-effort exception:
bounded losses while a plan remains live must recover. The documented limit
for a phone unreachable until the plan ends never excused #116: its
confirmations reach the service at virtual second 315 or 5 before plan end,
and now recover the accepted revision.
The accepted trust in the suggester's claim of unanimity remains ADR 0243's
limit; a public roster digest is correlation data, not cryptographic proof of
other people's votes.

No production interface or service is changed here. Core's #98 revision trap,
A's app wiring, and D's asked-roster place follow-up stay separate. The
Orchestrator runs #107's gate; F does not rerun it in this increment.

## Sources

- ADR 0022, accepted product behavior, read 2026-10-03.
- ADRs 0023 and 0243, PR #111 merged at 7e285f5, including acknowledged
  withdrawals, leave/confirmation commutation, and forwarded departures,
  read 2026-10-05.
- The Orchestrator's 2026-10-05 confirmation that #111 merged: rebase #107,
  update changed expectations, run the Simulator suite, and mark it ready.
- Issues #113,
  #114,
  #116, and
  #117: executed
  reproductions and controls from this lane.
- Issue #119:
  four findings already routed by the Orchestrator's re-review, reproduced
  as PC35 to PC38 on b785f29 and passing without wrappers on e8892a1.
