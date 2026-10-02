import Foundation
import StarlingChaining
import StarlingCore

/// Lane E's `EgressJournal` on the phone (ADR 0021 decision 4, P15-E request
/// 4.1), in `Application Support/Starling/egress-journal.json` (ADR 0200's
/// helper): the sends whose "What left your phone" record is not yet
/// confirmed on their interaction.
///
/// Every `remember` and `forget` is written before it returns and throws
/// when it cannot be, so `EgressRecorder.willSend` stops a send it could
/// not note. A file that exists but cannot be read throws, so the recorder
/// reports the journal unreadable and the app claims nothing stayed on the
/// phone. The cache changes only after a write succeeds.
public actor FileEgressJournal: EgressJournal {
    public struct Unreadable: Error, Hashable, Sendable {}

    struct Document: Codable {
        var version = 1
        var entries: [EgressJournalEntry] = []
    }

    private let file: JSONFile
    private var cache: [EgressJournalEntry]?

    public init(file: JSONFile) {
        self.file = file
    }

    public static func standard() throws -> FileEgressJournal {
        FileEgressJournal(file: try .standard("egress-journal.json"))
    }

    public func remember(_ entry: EgressJournalEntry) async throws {
        var next = try loaded()
        if let index = next.firstIndex(where: { $0.message == entry.message }) {
            next[index] = entry
        } else {
            next.append(entry)
        }
        try commit(next)
    }

    public func forget(_ message: MessageID) async throws {
        var next = try loaded()
        guard next.contains(where: { $0.message == message }) else { return }
        next.removeAll { $0.message == message }
        try commit(next)
    }

    public func unresolved() async throws -> [EgressJournalEntry] {
        try loaded()
    }

    private func loaded() throws -> [EgressJournalEntry] {
        if let cache { return cache }
        do {
            let entries = try file.read(Document.self)?.entries ?? []
            cache = entries
            return entries
        } catch {
            throw Unreadable()
        }
    }

    private func commit(_ entries: [EgressJournalEntry]) throws {
        try file.write(Document(entries: entries))
        cache = entries
    }
}

/// Hands every send to several observers: lane E's egress recorder and lane
/// G's audit log. `willSend` runs them in order, and the first that throws
/// stops the send.
public struct FanOutObserver: OutboxObserver {
    private let observers: [any OutboxObserver]

    public init(_ observers: [any OutboxObserver]) {
        self.observers = observers
    }

    public func outbox(willSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async throws {
        for observer in observers { try await observer.outbox(willSend: envelope, context: context, decision: decision, disclosed: disclosed) }
    }

    public func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {
        await outbox(didSend: envelope, context: context, decision: decision, disclosed: nil)
    }

    public func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async {
        for observer in observers { await observer.outbox(didSend: envelope, context: context, decision: decision, disclosed: disclosed) }
    }
}

/// Stands in when the journal's file cannot even be located: every call
/// throws, so the recorder stops each send in `willSend` rather than let one
/// leave unrecorded.
public struct UnavailableEgressJournal: EgressJournal {
    public struct Unavailable: Error {}
    public init() {}
    public func remember(_ entry: EgressJournalEntry) async throws { throw Unavailable() }
    public func forget(_ message: MessageID) async throws { throw Unavailable() }
    public func unresolved() async throws -> [EgressJournalEntry] { throw Unavailable() }
}
