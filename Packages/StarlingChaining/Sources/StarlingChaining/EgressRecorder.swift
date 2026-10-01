import Foundation
import StarlingCore

// "What left your phone" is recorded at the one place every send passes:
// the Outbox (ADR 0011 decision 5, ADR 0241). After each envelope the
// transport accepted, the recorder writes an `EgressRecord` onto the
// interaction whose conversation the envelope belongs to, using the same
// `DisclosedItem`s the policy computed for the consent sheet.
//
// The audit must never claim something stayed on the phone when its log is
// incomplete. So a record whose items could not be computed carries a
// marker, a write that failed is kept and retried (idempotently, by the
// envelope's ID), and `unconfirmedConversations` names every conversation
// whose log may be missing a send.

/// Writes egress records onto interactions. The app's lifecycle
/// coordinator implements it, so every write to an interaction goes through
/// the one place that already serializes them (ADR 0011 decision 7).
public protocol EgressSink: Sendable {
    /// Appends `record`, for the envelope `message`, to the interaction
    /// whose conversation is `conversation`. Returns false when there is none
    /// on this phone. Must be idempotent per `message`: the recorder retries
    /// a write that threw, and the first attempt may have landed.
    func appendEgress(_ record: EgressRecord, message: MessageID, conversation: ConversationID) async throws -> Bool
}

/// The policy's own list of what an envelope discloses: in the app,
/// `DeterministicPolicyEngine.disclosure(for:)`'s items. Used for sends the
/// policy allowed without a sheet; a send that needed consent records the
/// sheet's items exactly.
public typealias DisclosedItemsForSend = @Sendable (Envelope, OutboundContext) throws -> [DisclosedItem]

extension EgressRecord {
    /// Stands in for the items of a send whose items could not be computed.
    /// The policy never discloses terms without an issue, so it cannot be
    /// mistaken for a real item.
    public static let unknownItems = DisclosedItem(category: .terms, issue: nil, value: nil)

    /// Whether this send's items are unknown, so the audit cannot say what
    /// it disclosed.
    public var itemsUnknown: Bool { items.contains(Self.unknownItems) }
}

/// Install with `Outbox(observer:)`.
public actor EgressRecorder: OutboxObserver {
    /// At most this many failed writes wait for a retry; older ones are
    /// dropped, and their conversations stay unconfirmed.
    public static let maxPending = 256

    private struct Pending {
        let message: MessageID
        let conversation: ConversationID
        let record: EgressRecord
    }

    private let sink: any EgressSink
    private let itemsForSend: DisclosedItemsForSend
    private let now: @Sendable () -> Date
    private var pending: [Pending] = []
    /// Conversations that lost a record for good (the retry queue was full).
    private var lost: Set<ConversationID> = []
    /// Writes under way, per conversation: not yet confirmed either.
    private var writing: [ConversationID: Int] = [:]

    /// Sends for a conversation no interaction on this phone owns, such as a
    /// link-level `hello`. The policy's audit log still has them.
    public private(set) var unattributed = 0
    /// Allowed sends whose items could not be computed. Recorded with
    /// `EgressRecord.unknownItems`, so the send still shows and the audit
    /// knows it cannot vouch for that interaction.
    public private(set) var unexplained = 0
    /// Write attempts the sink rejected, retries included.
    public private(set) var failedWrites = 0

    public init(sink: any EgressSink, itemsForSend: @escaping DisclosedItemsForSend, now: @escaping @Sendable () -> Date = { Date() }) {
        self.sink = sink
        self.itemsForSend = itemsForSend
        self.now = now
    }

    public func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {
        let items: [DisclosedItem]
        switch decision {
        case .needsConsent(let disclosure):
            // Exactly what the sheet showed and the owner approved.
            items = disclosure.items
        case .allow:
            do {
                items = try itemsForSend(envelope, context)
            } catch {
                unexplained += 1
                items = [EgressRecord.unknownItems]
            }
        case .deny:
            // Outbox never reports a denied send.
            return
        }
        await retryPending()
        let record = EgressRecord(at: Timestamp(now()), recipient: envelope.recipient, items: items)
        await write(Pending(message: envelope.id, conversation: envelope.conversation, record: record))
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
            if try await !sink.appendEgress(item.record, message: item.message, conversation: item.conversation) { unattributed += 1 }
        } catch {
            failedWrites += 1
            if pending.count == Self.maxPending { lost.insert(pending.removeFirst().conversation) }
            pending.append(item)
        }
    }
}

/// An `EgressSink` over an `InteractionStore`: read, record, save. Safe only
/// when every other write to the store goes through the same actor; the
/// app's coordinator should be the sink instead. For tests and tools. It
/// remembers the envelopes it recorded in memory, which makes a retry within
/// one launch idempotent.
public actor StoreEgressSink: EgressSink {
    private let store: any InteractionStore
    private var recorded: Set<MessageID> = []

    public init(store: any InteractionStore) { self.store = store }

    public func appendEgress(_ record: EgressRecord, message: MessageID, conversation: ConversationID) async throws -> Bool {
        guard var interaction = try await store.interaction(conversation: conversation) else { return false }
        guard !recorded.contains(message) else { return true }
        interaction.record(record)
        try await store.save(interaction)
        recorded.insert(message)
        return true
    }
}
