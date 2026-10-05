# ADR 0259: Authenticated plan-change regression boundaries

- Status: Proposed
- Date: 2026-10-03
- Owner: P15-F
- Builds on: ADRs 0022, 0243, 0253, 0254, 0257, 0258

## Decision

Exercise the real ChangePlanService and ChainPlanner on lane E's PR #111.
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

On lane E `e8892a1`, the targeted change-plan/updater rerun passes 38 tests in
8 suites with zero known issues. All assertions for #114, #116, #117 and #119
are ordinary regressions again; PC06 and #113 also pass. PC04/PC32 distinguish
a durable accepted offer from an applied receipt and require the journal to
stay unchanged after forged confirmation. PC08 requires the intended
window-close withdrawals to name the original offers at the same deadline,
while the declining phone still sends nothing.

The stacked branch's standalone Simulator run has three failures in two older
place integration tests because E's new updater needs the next-revision
proposal plan supplied by #118. Main `500599e` contains #118; an isolated merge
validates the combined code without rebasing #107 before #111 merges. The
integration assertions remain unchanged. A `waitRevision` predicate treats a
joining friend's absent plan artifact as pending rather than throwing an
assertion before the event arrives. Intermittent older app/place cases remain
tracked in #121; the final integrated Simulator run still times out in the
unchanged shortened-place-roster test, so full-suite verification is not green.
See the request log for every failed run and the passing targeted checks.
Exact evidence and remaining matrix
subcases are in docs/requests/P15-F.md; device steps 22 to 34 remain unrun.

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
- ADR 0243 and PR #111 at e8892a1, including AcceptedOffer, recovery ordering,
  window-close withdrawals, and the plan updater, read 2026-10-05.
- The Orchestrator's 2026-10-05 instructions: update PC04/PC08/PC32 for those
  intended changes; keep #107 draft and rebase onto main after #111 merges.
- Issues [#113](https://github.com/oliverrowebardeen/starling-ios/issues/113),
  [#114](https://github.com/oliverrowebardeen/starling-ios/issues/114),
  [#116](https://github.com/oliverrowebardeen/starling-ios/issues/116), and
  [#117](https://github.com/oliverrowebardeen/starling-ios/issues/117): executed
  reproductions and controls from this lane.
- Issue [#119](https://github.com/oliverrowebardeen/starling-ios/issues/119):
  four findings already routed by the Orchestrator's re-review, reproduced
  as PC35 to PC38 on b785f29 and passing without wrappers on e8892a1.
