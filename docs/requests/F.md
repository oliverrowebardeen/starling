# Lane F requests

Interface change requests from the Negotiation lane. Everything below has a local workaround, so none of it blocks Phase 1.

## Status (Core v1.1, merged to main at c4debe0)

| # | Request | Answer | Lane F follow-up |
|---|---------|--------|------------------|
| 1 | `handle(_:)` on `DownService` | Done | `DownNegotiator` conforms; the tests drive it through `any DownService` |
| 2 | A key for the Down level | Done: `IssueKey.downLevel` | Used instead of spelling `down_level` |
| 3 | Currency check in `violations` | Done: `LimitViolation.Reason.currencyMismatch` | Local special case removed |
| 4 | Feature tag per conversation | Deferred to Phase 2 | Phase 1 routes every conversation to Down |
| 5 | Consent memory for retries | Assigned to lane H's consent coordinator | None |
| 6 | Test-only `StarlingTransport` dependency | Approved | None |

Also adopted from v1.1: `Answer.issue` (answers name their issue, and an answer whose issue differs from the query is ignored) and `OutboundContext.psi` on every PSI step (provider descriptor plus the time slots the set was built from).

## 1. Add `handle(_:)` to `DownService`

What: add the Inbox entry point to the protocol, and a matching method to `ScriptedDownService`.

```swift
public protocol DownService: Sendable {
    var events: AsyncStream<DownEvent> { get }
    func setIntent(_ intent: DownIntent) async throws
    func clearIntent() async
    /// Every InboxEvent from the app's single Inbox loop.
    func handle(_ event: InboxEvent) async
}
```

Why: ARCHITECTURE section 2 says the app owns the one Inbox loop, and the kickoff asks for "an entry point the app calls with each InboxEvent." Without it in the protocol, lane H can only wire the concrete `DownNegotiator`, not `any DownService`, and cannot swap in the fake.

Meanwhile: `DownNegotiator.handle(_:)` exists as a public method on the concrete type.

## 2. A field or constant for the Down level in an acceptance

What, either of:

- (additive) `public static let downLevel = IssueKey(known: "down_level")` on `IssueKey`, so policy and the consent sheet can name it; or
- (wire change, next freeze) `Acceptance.level: DownLevel?`.

Why: ARCHITECTURE section 7, step 6 exchanges levels only at accept time, and `Acceptance` has no place for one. ADR 0120 carries the level in the accept's terms under `down_level`.

Meanwhile: `StarlingNegotiation` uses `try IssueKey("down_level")`. Lane G: an accept's terms therefore contain one issue that is not part of the plan. It should appear on the consent sheet as "whether you said down or maybe," and it must not be treated as an unknown issue that blocks the send.

## 3. `ConstraintSet.violations` and currencies

What: treat a budget in a different currency from an `atMost`/`atLeast` limit as a violation (for example a new `LimitViolation.Reason.currencyMismatch`), instead of passing it.

Why: today `violations` returns nothing for `atMost($15)` against `€1,000`, so a peer could slip an unbounded budget past any code that relies on `violations` alone. `DownProfile.isWellFormed` refuses it locally (test: `DownProfileTests.malformedPlansFail`), but the agent lane's prompt marking and any future feature would not.

Meanwhile: checked in `StarlingNegotiation`.

## 4. Telling a conversation's feature apart (Phase 2)

What: a way for the receiver to know which feature a conversation belongs to, for example a `feature: Capability` on the first message of a conversation, or on `Envelope`.

Why: `DownNegotiator` treats any conversation that opens with a PSI step 0 as Down. That is fine while Down is the only feature, but scheduling and group decision will also use `query`, `propose`, and `psi`.

Meanwhile: in Phase 1 the app routes every conversation to the Down service.

## 5. Consent for retries (for lanes G and H)

What: when the policy asks for consent on a message, remember the owner's answer for the rest of that conversation (same recipient, same `ConversationID`, same body), so that a retry does not show the sheet again.

Why: delivery is best effort, so Down resends a step up to 6 times (ADR 0120). Every `Outbox.send` evaluates the policy again. While the PSI stub forces consent, every retry of a PSI frame would show a new sheet.

Meanwhile: Down starts the retry timer only after the first send returns, so a sheet that is still open delays retries rather than stacking them.

## 6. Test-only dependency on StarlingTransport

What: `Packages/StarlingNegotiation/Package.swift` depends on `../StarlingTransport`, used only by the test target (for `LoopbackHub`, which the kickoff asks the tests to use). The library target depends on `StarlingCore` alone.

Why it needs a note: ADR 0006 routes dependencies between non-core packages through the Orchestrator.

## Answers to lane H (`docs/requests/H.md` section 4, on `phase-1/h-app`)

### 1. Building the Down service with the app's Outbox

The initializer is public and takes an `Outbox` the app builds, so the app keeps the policy, the consent sheet, and any `OutboxObserver`:

```swift
makeDownService: { consent in
    let outbox = Outbox(transport: secureChannel, policy: policy, consent: consent, observer: auditLog)
    return DownNegotiator(
        localPeer: identity.peerID,      // must equal the Outbox transport's localPeer
        outbox: outbox,
        pairedPeers: pairedPeerStore,
        model: agentModel,
        psi: psiProvider                 // InsecurePSIStub() until Nightjar lands
    )
}
```

Defaults: `clock: .system`, `timeZone: .current`, `configuration: DownConfiguration()` (5 s retries, 6 attempts).

The app's side of the contract:

- Pass **every** `InboxEvent` to `handle(_:)`, including `peerAvailable`/`peerUnavailable` (they decide which friends are asked) and `hello` (Down records the card and skips friends whose card lacks `Capability.down`). Down does not send `hello`; the app's link layer does.
- `setIntent` throws `DownError.expired` if the expiry is not in the future, and `DownError.noAvailableTime` if the rules leave no free half-hour before it. Keep the review open with a message in both cases.
- Every Outbox error other than a lost frame (`denied`, `consentDeclined`, `policyChangedDuringConsent`) ends that friend's run for the rest of the intent, silently.
- Call `shutdown()` when tearing the service down.

For the "does matching hide free time" note, `downService.psiProvider.isPrivate` is `nonisolated` and needs no `await`. The app can also read `descriptor.isPrivate` from the provider it passed in.

For the consent coordinator: when Down ends a conversation (the owner clears Down, the intent expires, or a friend's run ends), it cancels the task running that `Outbox.send`. The Outbox then sends nothing, whatever the owner answers. A sheet still on screen for a cancelled send should be dismissed; `ConsentProvider.requestConsent` can observe this with `withTaskCancellationHandler`.

### 2. One merged `OwnerRules` per intent

Yes. One merged `OwnerRules` per intent (ADR 0141: constraints accumulate, the most restrictive sharing wins) is what `DownIntent.rules` expects. What Down reads from it:

- **Time:** hard `within` and `dailyWindow` constraints filter the free half-hours. Accumulating is correct: a slot must pass all of them.
- **Activity:** `prefers(liked:avoided:)`. Avoided keywords from every constraint are always refused. Liked keywords are taken **in order**, and the first one both sides accept goes into the plan. Please put the intent's constraints before the standing ones on the same issue, so "want food tonight" outranks a standing preference.
- **Budget:** the lowest `atMost` in the owner's currency.
- **Expiry:** `DownIntent.expiresAt` also bounds the plan: slots must end by it. Set it at or after the end of the latest window the owner stated.

Down does not read `disclosure`; the policy enforces it. Two consequences to show in review:

- A `never` rule on `time` makes the policy refuse every PSI step, so Down cannot run at all.
- A `never` rule on `activity` or `budget` makes the policy refuse that query, and the run with that friend ends without a match. Leaving withheld issues out of the exchange instead is a candidate Phase 2 change (ADR 0121).

## Phase 2 candidates

### Offer window intersections as options (from lane C2)

Lane C2 found that two agents converge only on an option one of them listed. In the `down-2p` bench scenario the windows overlap (20:00 to 23:00), but neither side lists that overlap, and they reject after 6 rounds.

Down v1 does not hit this: the time in the opening offer is the PSI intersection, computed in code, and the model never proposes a time (ADR 0121). It matters for Phase 2 negotiations where `decide` weighs times, such as scheduling and group decision. I agree with building in code the intersections of both sides' known windows and offering them to `decide` as options, the same "code lists compliant options, the model picks" pattern as ADR 0121. That is a design for the Phase 2 negotiation lane, not a Phase 1 change.
