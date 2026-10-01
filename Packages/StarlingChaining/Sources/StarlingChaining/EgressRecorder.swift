import Foundation
import StarlingCore

// "What left your phone" is recorded at the one place every send passes:
// the Outbox (ADR 0011 decision 5, ADR 0241). After each envelope the
// transport accepted, the recorder writes an `EgressRecord` onto the
// interaction whose conversation the envelope belongs to, using the same
// `DisclosedItem`s the policy computed for the consent sheet.

/// Writes egress records onto interactions. The app's lifecycle
/// coordinator implements it, so every write to an interaction goes through
/// the one place that already serializes them (ADR 0011 decision 7).
public protocol EgressSink: Sendable {
    /// Appends `record` to the interaction whose conversation is
    /// `conversation`. Returns false when there is none on this phone.
    func appendEgress(_ record: EgressRecord, conversation: ConversationID) async throws -> Bool
}

/// The policy's own list of what an envelope discloses: in the app,
/// `DeterministicPolicyEngine.disclosure(for:)`'s items. Used for sends the
/// policy allowed without a sheet; a send that needed consent records the
/// sheet's items exactly.
public typealias DisclosedItemsForSend = @Sendable (Envelope, OutboundContext) throws -> [DisclosedItem]

/// Install with `Outbox(observer:)`.
public actor EgressRecorder: OutboxObserver {
    private let sink: any EgressSink
    private let itemsForSend: DisclosedItemsForSend
    private let now: @Sendable () -> Date

    /// Sends for a conversation no interaction on this phone owns, such as a
    /// link-level `hello`. The policy's audit log still has them.
    public private(set) var unattributed = 0
    /// Allowed sends whose items could not be computed. Recorded with no
    /// items, so the send still shows; counted so tests and Developer can
    /// see it happen.
    public private(set) var unexplained = 0
    /// Records the sink failed to write.
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
                items = []
            }
        case .deny:
            // Outbox never reports a denied send.
            return
        }
        let record = EgressRecord(at: Timestamp(now()), recipient: envelope.recipient, items: items)
        do {
            if try await !sink.appendEgress(record, conversation: envelope.conversation) { unattributed += 1 }
        } catch {
            failedWrites += 1
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
