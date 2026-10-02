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

/// One send whose record is not yet confirmed on its interaction.
public struct EgressJournalEntry: Hashable, Sendable, Codable {
    public let message: MessageID
    public let conversation: ConversationID
    public let record: EgressRecord
    /// False from `willSend` until Outbox confirms the transport took the
    /// envelope. An entry still false at launch may or may not have left,
    /// so its record is written as unknown.
    public let sent: Bool
    /// The envelope carried a skill, so an interaction on this phone owns
    /// its conversation, even if the coordinator has not created it yet: the
    /// record waits for it rather than being dropped. False only for a
    /// link-level envelope such as `hello`.
    public let skilled: Bool

    public init(message: MessageID, conversation: ConversationID, record: EgressRecord, sent: Bool, skilled: Bool) {
        self.message = message
        self.conversation = conversation
        self.record = record
        self.sent = sent
        self.skilled = skilled
    }

    private enum CodingKeys: String, CodingKey { case message, conversation, record, sent, skilled }

    /// An entry written before `skilled` existed waits for its interaction,
    /// the safe reading.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(message: c.decode(MessageID.self, forKey: .message), conversation: c.decode(ConversationID.self, forKey: .conversation),
                      record: c.decode(EgressRecord.self, forKey: .record), sent: c.decode(Bool.self, forKey: .sent),
                      skilled: c.decodeIfPresent(Bool.self, forKey: .skilled) ?? true)
    }
}

/// Durable memory of the sends the recorder has not yet confirmed, so the
/// audit's uncertainty survives a crash or restart (ADR 0021 decision 4). An
/// entry is written in `willSend`, before the transport takes the envelope,
/// updated when the send is confirmed, and removed only once its record is
/// on the interaction. The app keeps it on disk (lane A); a restarted
/// recorder reads it in `recover()`. `InMemoryEgressJournal` is for tests.
public protocol EgressJournal: Sendable {
    /// Adds the entry, or replaces the one for the same envelope. Durable
    /// before it returns.
    func remember(_ entry: EgressJournalEntry) async throws
    func forget(_ message: MessageID) async throws
    /// Every entry not yet forgotten, oldest first.
    func unresolved() async throws -> [EgressJournalEntry]
}

/// An `EgressJournal` in memory. Survives a recorder, not the app: tests
/// share one between two recorders to stand in for a restart.
public actor InMemoryEgressJournal: EgressJournal {
    public struct Unavailable: Error {}
    private var entries: [EgressJournalEntry] = []
    private var failing = false

    public init() {}

    /// Makes every later call throw, as a full or broken disk would.
    public func failAll() { failing = true }

    public func remember(_ entry: EgressJournalEntry) async throws {
        if failing { throw Unavailable() }
        if let index = entries.firstIndex(where: { $0.message == entry.message }) { entries[index] = entry } else { entries.append(entry) }
    }

    public func forget(_ message: MessageID) async throws {
        if failing { throw Unavailable() }
        entries.removeAll { $0.message == message }
    }

    public func unresolved() async throws -> [EgressJournalEntry] {
        if failing { throw Unavailable() }
        return entries
    }
}

/// Install with `Outbox(observer:)`.
///
/// Every send stays unresolved, and its conversation unconfirmed, from the
/// moment Outbox announces it in `willSend` until the sink has put its record
/// on the interaction: through the transport, a write under way, a failure,
/// a retry, and a crash or restart alike. If the journal cannot note a send,
/// `willSend` throws and Outbox sends nothing. Call `recover()` at launch,
/// before showing any audit.
public actor EgressRecorder: OutboxObserver {
    /// At most this many unresolved sends are kept for a retry; past that the
    /// oldest confirmed one is dropped, and its conversation stays
    /// unconfirmed. Its journal entry stays, so a restart brings it back.
    public static let maxPending = 256

    private struct Pending {
        let conversation: ConversationID
        var record: EgressRecord
        /// Outbox confirmed the transport took it. Only then is it written.
        var sent: Bool
        /// A skill conversation: if no interaction owns it yet, the record
        /// waits for one instead of being dropped.
        let skilled: Bool
    }

    private let sink: any EgressSink
    private let journal: any EgressJournal
    private let now: @Sendable () -> Date
    /// Sends not yet confirmed on their interaction, by envelope, oldest first.
    private var pending: [MessageID: Pending] = [:]
    private var order: [MessageID] = []
    /// Sends whose sink call is under way, so two retries never write one
    /// send at the same time.
    private var attempting: Set<MessageID> = []
    /// Conversations that lost a record for good (the retry queue was full).
    private var lost: Set<ConversationID> = []

    /// Link-level sends (no skill, such as `hello`) for a conversation no
    /// interaction on this phone owns. The policy's audit log still has
    /// them. A skill send never counts here: it waits for its interaction.
    public private(set) var unattributed = 0
    /// Sends the policy could not explain. Recorded with `itemsUnknown`, so
    /// the send still shows and the audit knows it cannot vouch for that
    /// interaction.
    public private(set) var unexplained = 0
    /// Times a skill send found no interaction for its conversation yet and
    /// was kept waiting.
    public private(set) var waitingForInteraction = 0
    /// Write attempts the sink rejected, retries included.
    public private(set) var failedWrites = 0
    /// Journal operations that failed. A failure in `willSend` stops the
    /// send; a later one leaves an entry that a restart resolves.
    public private(set) var journalFailures = 0
    /// The journal could not be read at launch, so the app cannot know which
    /// logs are complete: it should not claim anything stayed on the phone.
    public private(set) var journalUnreadable = false

    public init(sink: any EgressSink, journal: any EgressJournal, now: @escaping @Sendable () -> Date = { Date() }) {
        self.sink = sink
        self.journal = journal
        self.now = now
    }

    /// At launch: brings back every send the journal still holds, so its
    /// conversation is unconfirmed again, and records it. A send that was
    /// announced but never confirmed may or may not have left, so it is
    /// recorded with `itemsUnknown` (ADR 0021 decision 4).
    public func recover() async {
        let entries: [EgressJournalEntry]
        do {
            entries = try await journal.unresolved()
        } catch {
            journalUnreadable = true
            journalFailures += 1
            return
        }
        for entry in entries {
            let record = entry.sent ? entry.record
                : EgressRecord(at: entry.record.at, recipient: entry.record.recipient, items: entry.record.items, message: entry.message, itemsUnknown: true)
            track(entry.message, Pending(conversation: entry.conversation, record: record, sent: true, skilled: entry.skilled))
        }
        await retryPending()
    }

    /// Before the transport: notes the send durably as pending, with what it
    /// discloses. Throws, and Outbox sends nothing, if the journal cannot.
    public func outbox(willSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async throws {
        if case .deny = decision { return }
        let record = Self.record(for: envelope, disclosed: disclosed, at: now())
        // Tracked before the first suspension, so the conversation is
        // unconfirmed from the moment the send is announced.
        track(envelope.id, Pending(conversation: envelope.conversation, record: record, sent: false, skilled: envelope.skill != nil))
        do {
            try await journal.remember(EgressJournalEntry(message: envelope.id, conversation: envelope.conversation, record: record, sent: false, skilled: envelope.skill != nil))
        } catch {
            journalFailures += 1
            // Not sent, so nothing to record: forget it here too.
            pending[envelope.id] = nil
            order.removeAll { $0 == envelope.id }
            throw error
        }
    }

    /// After the transport took the envelope: settles the pending note and
    /// records the send on its interaction. `disclosed` is what Outbox
    /// reports: the consent sheet's items, or for a send allowed without a
    /// sheet the policy's own list (`PolicyEngine.disclosedItems(for:)`), or
    /// nil when the policy could not say.
    public func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async {
        if case .deny = decision { return }  // Outbox never reports a denied send.
        if disclosed == nil { unexplained += 1 }
        // The envelope as sent carries its number and send time; the draft
        // announced in willSend has the same ID.
        let record = Self.record(for: envelope, disclosed: disclosed, at: now())
        if pending[envelope.id] == nil {
            track(envelope.id, Pending(conversation: envelope.conversation, record: record, sent: true, skilled: envelope.skill != nil))
        } else {
            pending[envelope.id]?.record = record
            pending[envelope.id]?.sent = true
        }
        do {
            try await journal.remember(EgressJournalEntry(message: envelope.id, conversation: envelope.conversation, record: record, sent: true, skilled: envelope.skill != nil))
        } catch {
            // The entry stays as announced; a restart records it as unknown,
            // or, if this record lands first, Interaction.record keeps this one.
            journalFailures += 1
        }
        await retryPending()
    }

    /// For a caller that cannot pass the items: only a sheet's are known.
    public func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {
        let disclosed: [DisclosedItem]? = if case .needsConsent(let disclosure) = decision { disclosure.items } else { nil }
        await outbox(didSend: envelope, context: context, decision: decision, disclosed: disclosed)
    }

    /// Writes every confirmed, unresolved send, oldest first, skipping any
    /// already being written. Each stays unresolved until its own write
    /// lands. The app calls it when the store recovers; every send also runs it.
    public func retryPending() async {
        for message in order where pending[message]?.sent == true && !attempting.contains(message) {
            await attempt(message)
        }
    }

    /// The coordinator created an interaction: records waiting for its
    /// conversation are written now.
    public func interactionArrived(conversation: ConversationID) async {
        for message in order where pending[message]?.conversation == conversation && pending[message]?.sent == true && !attempting.contains(message) {
            await attempt(message)
        }
    }

    /// Conversations whose egress log may be missing a send: one is on its
    /// way out, being written, waiting for a retry, or was dropped. Pass to
    /// `WhatLeftYourPhone` and `PlanTimeline` so they do not claim anything
    /// stayed on the phone there.
    public var unconfirmedConversations: Set<ConversationID> {
        lost.union(pending.values.map(\.conversation))
    }

    private static func record(for envelope: Envelope, disclosed: [DisclosedItem]?, at date: Date) -> EgressRecord {
        EgressRecord(at: Timestamp(date), recipient: envelope.recipient, items: disclosed ?? [], message: envelope.id, itemsUnknown: disclosed == nil)
    }

    private func track(_ message: MessageID, _ item: Pending) {
        guard pending[message] == nil else { return }
        pending[message] = item
        order.append(message)
        // Over the limit: drop the oldest confirmed send not being written.
        if order.count > Self.maxPending,
           let oldest = order.first(where: { pending[$0]?.sent == true && !attempting.contains($0) }) {
            if let dropped = pending.removeValue(forKey: oldest) { lost.insert(dropped.conversation) }
            order.removeAll { $0 == oldest }
        }
    }

    private func attempt(_ message: MessageID) async {
        guard let item = pending[message] else { return }
        attempting.insert(message)
        defer { attempting.remove(message) }
        do {
            if try await sink.appendEgress(item.record, conversation: item.conversation) {
                await resolve(message)
            } else if item.skilled {
                // The skill announced the interaction, but the coordinator
                // has not created it yet: keep the record pending and
                // journaled until it can land (interactionArrived, or the
                // next send's retry).
                waitingForInteraction += 1
            } else {
                unattributed += 1
                await resolve(message)
            }
        } catch {
            failedWrites += 1
        }
    }

    /// The record is on its interaction: only now is the journal entry
    /// removed. If removing it fails, a restart retries a record that
    /// `Interaction.record` then ignores.
    private func resolve(_ message: MessageID) async {
        pending[message] = nil
        order.removeAll { $0 == message }
        do { try await journal.forget(message) } catch { journalFailures += 1 }
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
