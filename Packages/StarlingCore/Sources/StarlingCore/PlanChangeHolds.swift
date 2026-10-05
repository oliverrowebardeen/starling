import Foundation

// One change to a plan at a time on this phone (ADR 0023). Each change names
// the revision it changes, which catches a stale change but cannot choose
// between two fresh ones: if friends said yes to both, phones that heard the
// confirmations in different orders would end on different plans. So every
// skill that changes a plan holds it first, and a phone neither starts nor
// says yes to a second change while one holds the plan.

/// Which change, if any, this phone is taking part in for each plan. Plans
/// are named by `Plan.origin`; changes by their own conversation. Shared by
/// every skill that changes a plan; the app creates one.
public protocol PlanChangeHolding: Sendable {
    /// Holds `plan` for `change`. True if the plan was free or `change`
    /// already holds it; false, changing nothing, if another change does.
    func hold(_ plan: ConversationID, for change: ConversationID) async -> Bool
    /// Ends `change`'s hold on `plan`. Does nothing if another change, or
    /// none, holds it.
    func release(_ plan: ConversationID, for change: ConversationID) async
    /// The change holding `plan`, if any.
    func holder(of plan: ConversationID) async -> ConversationID?
}

/// The in-memory holds the app uses. Nothing is saved: after a relaunch
/// each skill holds the plan again for every change it restores (ADR 0023
/// decision 5).
public actor PlanChangeHolds: PlanChangeHolding {
    private var holders: [ConversationID: ConversationID] = [:]
    private var watchers: [UUID: AsyncStream<[ConversationID: ConversationID]>.Continuation] = [:]

    public init() {}

    public func hold(_ plan: ConversationID, for change: ConversationID) -> Bool {
        if let current = holders[plan] { return current == change }
        holders[plan] = change
        publish()
        return true
    }

    public func release(_ plan: ConversationID, for change: ConversationID) {
        guard holders[plan] == change else { return }
        holders[plan] = nil
        publish()
    }

    public func holder(of plan: ConversationID) -> ConversationID? {
        holders[plan]
    }

    /// Every plan's holder, now and after each hold or release that changes
    /// one, so the app can show "another change is in progress" and take it
    /// away the moment the hold ends, without asking again. Keeps only the
    /// newest value if the reader falls behind.
    public func updates() -> AsyncStream<[ConversationID: ConversationID]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: [ConversationID: ConversationID].self, bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopWatching(id) }
        }
        watchers[id] = continuation
        continuation.yield(holders)
        return stream
    }

    private func stopWatching(_ id: UUID) {
        watchers[id] = nil
    }

    private func publish() {
        for watcher in watchers.values { watcher.yield(holders) }
    }
}
