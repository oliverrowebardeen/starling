import Foundation
import StarlingCore

// "What left your phone" is recorded at the one place every send passes:
// the Outbox (ADR 0011 decision 5, ADR 0241). After each envelope the
// transport accepted, the recorder writes an `EgressRecord` onto the
// interaction whose conversation the envelope belongs to, using the same
// `DisclosedItem`s the policy computed for the consent sheet.
//
// The audit must never claim something stayed on the phone when its log is
// incomplete. A send the policy could not explain is recorded with
// `itemsUnknown`, a write that failed is kept and retried (idempotently: the
// record carries the envelope's ID, and `Interaction.record` ignores a
// repeat), and `unconfirmedConversations` names every conversation whose log
// may be missing a send.

/// Writes egress records onto interactions. The app's lifecycle
/// coordinator implements it, so every write to an interaction goes through
/// the one place that already serializes them (ADR 0011 decision 7).
public protocol EgressSink: Sendable {
    /// Appends `record` to the interaction whose conversation is
    /// `conversation`, with `Interaction.record`, which ignores a record for
    /// an envelope already recorded. Returns false when there is no such
    /// interaction on this phone. The recorder retries a write that threw,
    /// and the first attempt may have landed.
    func appendEgress(_ record: EgressRecord, conversation: ConversationID) async throws -> Bool
}

/// Install with `Outbox(observer:)`.
public actor EgressRecorder: OutboxObserver {
    /// At most this many failed writes wait for a retry; older ones are
    /// dropped, and their conversations stay unconfirmed.
    public static let maxPending = 256

    private struct Pending {
        let conversation: ConversationID
        let record: EgressRecord
    }

    private let sink: any EgressSink
    private let now: @Sendable () -> Date
    private var pending: [Pending] = []
    /// Conversations that lost a record for good (the retry queue was full).
    private var lost: Set<ConversationID> = []
    /// Writes under way, per conversation: not yet confirmed either.
    private var writing: [ConversationID: Int] = [:]

    /// Sends for a conversation no interaction on this phone owns, such as a
    /// link-level `hello`. The policy's audit log still has them.
    public private(set) var unattributed = 0
    /// Sends the policy could not explain. Recorded with `itemsUnknown`, so
    /// the send still shows and the audit knows it cannot vouch for that
    /// interaction.
    public private(set) var unexplained = 0
    /// Write attempts the sink rejected, retries included.
    public private(set) var failedWrites = 0

    public init(sink: any EgressSink, now: @escaping @Sendable () -> Date = { Date() }) {
        self.sink = sink
        self.now = now
    }

    /// `disclosed` is what Outbox reports: the consent sheet's items, or for
    /// a send allowed without a sheet the policy's own list
    /// (`PolicyEngine.disclosedItems(for:)`), or nil when the policy could
    /// not say.
    public func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async {
        if case .deny = decision { return }  // Outbox never reports a denied send.
        if disclosed == nil { unexplained += 1 }
        await retryPending()
        let record = EgressRecord(at: Timestamp(now()), recipient: envelope.recipient, items: disclosed ?? [],
                                  message: envelope.id, itemsUnknown: disclosed == nil)
        await write(Pending(conversation: envelope.conversation, record: record))
    }

    /// For a caller that cannot pass the items: only a sheet's are known.
    public func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {
        let disclosed: [DisclosedItem]? = if case .needsConsent(let disclosure) = decision { disclosure.items } else { nil }
        await outbox(didSend: envelope, context: context, decision: decision, disclosed: disclosed)
    }

    /// Retries every failed write, oldest first. The app calls it when the
    /// store recovers; every new send also retries first.
    public func retryPending() async {
        let waiting = pending
        pending = []
        for item in waiting { await write(item) }
    }

    /// Conversations whose egress log may be missing a send: a write is under
    /// way, waits for a retry, or was dropped. Pass to `WhatLeftYourPhone` and
    /// `PlanTimeline` so they do not claim anything stayed on the phone there.
    public var unconfirmedConversations: Set<ConversationID> {
        lost.union(pending.map(\.conversation)).union(writing.keys)
    }

    private func write(_ item: Pending) async {
        writing[item.conversation, default: 0] += 1
        defer {
            writing[item.conversation]? -= 1
            if writing[item.conversation] == 0 { writing[item.conversation] = nil }
        }
        do {
            if try await !sink.appendEgress(item.record, conversation: item.conversation) { unattributed += 1 }
        } catch {
            failedWrites += 1
            if pending.count == Self.maxPending { lost.insert(pending.removeFirst().conversation) }
            pending.append(item)
        }
    }
}

/// An `EgressSink` over an `InteractionStore`: read, record, save. Safe only
/// when every other write to the store goes through the same actor; the
/// app's coordinator should be the sink instead. For tests and tools.
public actor StoreEgressSink: EgressSink {
    private let store: any InteractionStore

    public init(store: any InteractionStore) { self.store = store }

    public func appendEgress(_ record: EgressRecord, conversation: ConversationID) async throws -> Bool {
        guard var interaction = try await store.interaction(conversation: conversation) else { return false }
        interaction.record(record)
        try await store.save(interaction)
        return true
    }
}
