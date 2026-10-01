import Foundation
import StarlingCore

/// Returns the same decision for every message and records what it saw.
public actor FixedPolicyEngine: PolicyEngine {
    public private(set) var evaluated: [OutboundMessage] = []
    private let decision: @Sendable (OutboundMessage) -> PolicyDecision
    private let explain: (@Sendable (OutboundMessage) -> Disclosure)?

    /// - Parameter explain: What `disclosedItems(for:)` returns; without it,
    ///   the engine cannot say and throws `DisclosureUnavailable`.
    public init(_ decision: PolicyDecision, explain: (@Sendable (OutboundMessage) -> Disclosure)? = nil) {
        self.decision = { _ in decision }
        self.explain = explain
    }

    public init(decide: @escaping @Sendable (OutboundMessage) -> PolicyDecision, explain: (@Sendable (OutboundMessage) -> Disclosure)? = nil) {
        self.decision = decide
        self.explain = explain
    }

    public func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        evaluated.append(message)
        return decision(message)
    }

    public func disclosedItems(for message: OutboundMessage) async throws -> [DisclosedItem] {
        guard let explain else { throw DisclosureUnavailable() }
        return explain(message).items
    }
}

/// Answers every consent request with a fixed outcome and records requests.
public actor ScriptedConsentProvider: ConsentProvider {
    public private(set) var requests: [Disclosure] = []
    private let outcome: ConsentOutcome

    public init(_ outcome: ConsentOutcome) { self.outcome = outcome }

    public func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        requests.append(disclosure)
        return outcome
    }
}

/// Always returns the same availability answer.
public struct StaticAvailabilitySource: AvailabilitySource {
    public let kind: AvailabilitySourceKind
    public let answer: AvailabilityAnswer

    public init(kind: AvailabilitySourceKind, answer: AvailabilityAnswer) {
        self.kind = kind
        self.answer = answer
    }

    public func availability(for query: AvailabilityQuery) async throws -> AvailabilityAnswer {
        guard case .known(let free) = answer else { return answer }
        return .known(free: free.compactMap { $0.overlap(with: query.window) })
    }
}

/// Records every successful send the Outbox reports.
public actor RecordingOutboxObserver: OutboxObserver {
    public struct Record: Hashable, Sendable {
        public let envelope: Envelope
        public let context: OutboundContext
        public let decision: PolicyDecision
        /// Nil when the policy could not say what the send disclosed.
        public let disclosed: [DisclosedItem]?
    }

    public private(set) var records: [Record] = []

    public init() {}

    public func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async {
        records.append(Record(envelope: envelope, context: context, decision: decision, disclosed: disclosed))
    }

    public func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {
        records.append(Record(envelope: envelope, context: context, decision: decision, disclosed: nil))
    }
}

/// A `SentSequenceStore` in memory, shared between Outbox instances to
/// stand for one phone across relaunches.
public final class InMemorySentSequenceStore: SentSequenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var highest: [ConversationID: UInt64] = [:]

    public init() {}

    public func highestSent(in conversation: ConversationID) -> UInt64? {
        lock.withLock { highest[conversation] }
    }

    public func recordSent(_ sequence: UInt64, in conversation: ConversationID) {
        lock.withLock { highest[conversation] = max(highest[conversation] ?? 0, sequence) }
    }
}
