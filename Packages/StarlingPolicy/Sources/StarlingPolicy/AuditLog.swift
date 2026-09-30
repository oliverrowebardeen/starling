import Foundation
import StarlingCore

/// Coarse value shapes only. No counts, booleans, amounts, keywords, slots,
/// provider names, or PSI payloads are retained in audit storage.
public enum AuditValueKind: String, Hashable, Sendable {
    case slots, keywords, amount, flag, count

    init(_ value: IssueValue) {
        switch value {
        case .slots: self = .slots
        case .keywords: self = .keywords
        case .amount: self = .amount
        case .flag: self = .flag
        case .count: self = .count
        }
    }
}

public struct AuditItemSummary: Hashable, Sendable {
    /// Nil for card metadata, opaque PSI, or an answer whose issue is not on wire.
    public let issue: IssueKey?
    public let valueKind: AuditValueKind?
}

/// Means Outbox handed the frame to its transport successfully. It is not a
/// receipt from the peer. The timestamp is local completion time.
public struct AuditEntry: Hashable, Sendable {
    public let message: MessageID
    public let recipient: PeerID
    public let sentAt: Timestamp
    public let kind: MessageBody.Kind
    public let items: [AuditItemSummary]

    public init(sent envelope: Envelope, completedAt: Timestamp) {
        message = envelope.id
        recipient = envelope.recipient
        sentAt = completedAt
        kind = envelope.body.kind
        switch envelope.body {
        case .propose(let proposal), .counter(let proposal): items = Self.summarize(proposal.terms)
        case .accept(let acceptance): items = Self.summarize(acceptance.terms)
        case .query(let query): items = [AuditItemSummary(issue: query.issue, valueKind: AuditValueKind(query.candidates))]
        case .answer(let answer):
            items = answer.acceptable.map { [AuditItemSummary(issue: nil, valueKind: AuditValueKind($0))] } ?? []
        case .hello, .psi: items = [AuditItemSummary(issue: nil, valueKind: nil)]
        case .reject: items = []
        }
    }

    private static func summarize(_ terms: Terms) -> [AuditItemSummary] {
        terms.values.keys.sorted().map { AuditItemSummary(issue: $0, valueKind: AuditValueKind(terms.values[$0]!)) }
    }
}

/// Local storage only. Implementations must not export entries or retain raw
/// envelopes. Append is nonthrowing so a completed send is never retried merely
/// because a logging backend failed. Persistent storage is outside Phase 1 G.
public protocol AuditLog: Sendable {
    func append(_ entry: AuditEntry) async
    func entries() async -> [AuditEntry]
    func removeAll() async
}

public actor InMemoryAuditLog: AuditLog {
    public let capacity: Int
    private var storage: [AuditEntry] = []

    public init(capacity: Int = 1_000) throws {
        guard capacity > 0 else { throw ValidationError("InMemoryAuditLog.capacity", "must be positive") }
        self.capacity = capacity
    }

    public func append(_ entry: AuditEntry) {
        if storage.count == capacity { storage.removeFirst() }
        storage.append(entry)
    }

    public func entries() -> [AuditEntry] { storage }
    public func removeAll() { storage.removeAll() }
}

/// Composes the frozen Core Outbox with post-send audit storage. Every send
/// still goes through Core policy and consent. See docs/requests/G.md for the
/// Core observer needed by consumers that require a concrete Outbox.
public struct AuditedOutbox: Sendable {
    private let outbox: Outbox
    private let auditLog: any AuditLog
    private let now: @Sendable () -> Date

    public init(outbox: Outbox, auditLog: any AuditLog, now: @escaping @Sendable () -> Date = { Date() }) {
        self.outbox = outbox
        self.auditLog = auditLog
        self.now = now
    }

    @discardableResult
    public func send(
        _ body: MessageBody, to recipient: PeerID, conversation: ConversationID,
        recipientCard: AgentCard? = nil
    ) async throws -> Envelope {
        try Task.checkCancellation()
        let envelope = try await outbox.send(body, to: recipient, conversation: conversation, recipientCard: recipientCard)
        await auditLog.append(AuditEntry(sent: envelope, completedAt: Timestamp(now())))
        return envelope
    }
}
