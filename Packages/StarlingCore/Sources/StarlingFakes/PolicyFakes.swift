import Foundation
import StarlingCore

/// Returns the same decision for every message and records what it saw.
public actor FixedPolicyEngine: PolicyEngine {
    public private(set) var evaluated: [OutboundMessage] = []
    private let decision: @Sendable (OutboundMessage) -> PolicyDecision

    public init(_ decision: PolicyDecision) {
        self.decision = { _ in decision }
    }

    public init(decide: @escaping @Sendable (OutboundMessage) -> PolicyDecision) {
        self.decision = decide
    }

    public func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        evaluated.append(message)
        return decision(message)
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
