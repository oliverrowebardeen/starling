# Lane F requests

Interface change requests from the Negotiation lane. Everything below has a local workaround, so none of it blocks Phase 1.

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
