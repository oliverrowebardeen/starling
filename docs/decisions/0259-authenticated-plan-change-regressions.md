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

Keep the expected invariant even when a service fails it. File the precise
reproduction and wrap only its failing assertions with the issue number.
The setup, positive controls, authentication, timer conditions and unrelated
assertions remain ordinary failures. A wrapper must be removed when the owner
fixes the finding; an unexpected pass is not silently accepted.

## Evidence and limits

On lane E `b785f29`, 38 added tests cover service attacks, privacy, delivery and
Core revision values. The Simulator summary is 209 tests in 39 suites, with
8 expected assertion failures in 4 tests for #114, #116 and #117. #113's lost
offer/withdrawal case now passes. Exact cases and remaining matrix subcases
are in docs/requests/P15-F.md; device steps 22 to 31 remain unrun.

The requested ack/resend behavior is an invariant, not a best-effort exception:
bounded losses while a plan remains live must recover. The documented limit
for a phone unreachable until the plan ends does not explain #116, whose
confirmations reach the service at virtual second 315 or 5 before plan end.
The accepted trust in the suggester's claim of unanimity remains ADR 0243's
limit; a public roster digest is correlation data, not cryptographic proof of
other people's votes.

No production interface or service is changed here. Core's #98 revision trap,
A's app wiring, and D's asked-roster place follow-up stay separate. The
Orchestrator runs #107's gate; F does not rerun it in this increment.

## Sources

- ADR 0022, accepted product behavior, read 2026-10-03.
- ADR 0243 and PR #111 at b785f29, including the delivery journal, retry schedule,
  roster digest and Orchestrator's place-roster decision, read 2026-10-03.
- Issues [#113](https://github.com/oliverrowebardeen/starling-ios/issues/113),
  [#114](https://github.com/oliverrowebardeen/starling-ios/issues/114),
  [#116](https://github.com/oliverrowebardeen/starling-ios/issues/116), and
  [#117](https://github.com/oliverrowebardeen/starling-ios/issues/117): executed
  reproductions and controls from this lane.
