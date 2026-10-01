import Foundation
import StarlingCore

/// Coarse value shapes only. No counts, booleans, amounts, keywords, slots,
/// provider names, or PSI payloads are retained in audit storage.
public enum AuditValueKind: String, Hashable, Sendable {
    case slots, keywords, amount, flag, count, places

    init(_ value: IssueValue) {
        switch value {
        case .slots: self = .slots
        case .keywords: self = .keywords
        case .amount: self = .amount
        case .flag: self = .flag
        case .count: self = .count
        case .places: self = .places
        }
    }
}

public struct AuditItemSummary: Hashable, Sendable {
    /// Nil for card metadata or PSI without semantic inputs.
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

    public init(sent envelope: Envelope, context: OutboundContext = .empty, completedAt: Timestamp) {
        message = envelope.id
        recipient = envelope.recipient
        sentAt = completedAt
        kind = envelope.body.kind
        switch envelope.body {
        case .propose(let proposal), .counter(let proposal): items = Self.summarize(proposal.terms.values)
        case .accept(let acceptance): items = Self.summarize(acceptance.terms.values)
        case .query(let query): items = [AuditItemSummary(issue: query.issue, valueKind: AuditValueKind(query.candidates))]
        case .answer(let answer):
            items = answer.acceptable.map { [AuditItemSummary(issue: answer.issue, valueKind: AuditValueKind($0))] } ?? []
        case .psi:
            if let psi = context.psi, !psi.inputs.isEmpty {
                items = Self.summarize(psi.inputs, includesValueKinds: !psi.provider.isPrivate)
            } else {
                items = [AuditItemSummary(issue: nil, valueKind: nil)]
            }
        case .hello: items = [AuditItemSummary(issue: nil, valueKind: nil)]
        case .reject: items = []
        }
    }

    private static func summarize(_ values: [IssueKey: IssueValue], includesValueKinds: Bool = true) -> [AuditItemSummary] {
        values.keys.sorted().map { AuditItemSummary(issue: $0, valueKind: includesValueKinds ? AuditValueKind(values[$0]!) : nil) }
    }
}

/// Local storage only. Implementations must not export entries or retain raw
/// envelopes. Append is nonthrowing so a completed send is never retried merely
/// because a logging backend failed. Persistent storage is outside Phase 1 G.
public protocol AuditLog: OutboxObserver {
    func append(_ entry: AuditEntry) async
    func entries() async -> [AuditEntry]
    func removeAll() async
}

public actor InMemoryAuditLog: AuditLog {
    public let capacity: Int
    private var storage: [AuditEntry] = []
    private let now: @Sendable () -> Date

    public init(capacity: Int = 1_000, now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard capacity > 0 else { throw ValidationError("InMemoryAuditLog.capacity", "must be positive") }
        self.capacity = capacity
        self.now = now
    }

    /// Install with Outbox(observer:). The callback arrives only after send
    /// success. Neither the original context nor consent Disclosure is stored.
    public func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) {
        append(AuditEntry(sent: envelope, context: context, completedAt: Timestamp(now())))
    }

    public func append(_ entry: AuditEntry) {
        if storage.count == capacity { storage.removeFirst() }
        storage.append(entry)
    }

    public func entries() -> [AuditEntry] { storage }
    public func removeAll() { storage.removeAll() }
}
