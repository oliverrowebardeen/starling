import Foundation
import StarlingCore

/// A deterministic `AgentModel` driven by closures. The default `match` returns
/// exact keyword matches only; the other tasks throw `.unsupported` until scripted.
public struct ScriptedAgentModel: AgentModel {
    public var descriptor: ModelDescriptor
    /// Reported on every result so harness code paths can be exercised.
    public var usage: TokenUsage?
    public var latency: Duration

    public var onInterpret: @Sendable (OwnerUtterance, InterpretationContext) async throws -> OwnerRules
    public var onMatch: @Sendable ([Keyword], [Keyword]) async throws -> [KeywordMatch]
    public var onDecide: @Sendable (NegotiationContext) async throws -> NegotiationMove

    public init(
        descriptor: ModelDescriptor = ModelDescriptor(identifier: "fake.scripted", locality: .onDevice, contextSize: 4096),
        usage: TokenUsage? = nil,
        latency: Duration = .zero,
        onInterpret: @escaping @Sendable (OwnerUtterance, InterpretationContext) async throws -> OwnerRules = { _, _ in
            throw AgentModelError.unsupported
        },
        // A closure literal, not a method reference: converting the static
        // method directly crashed intermittently under Swift 6.2.1 (the thunk
        // passed a garbage array).
        onMatch: @escaping @Sendable ([Keyword], [Keyword]) async throws -> [KeywordMatch] = { wanted, offered in
            ScriptedAgentModel.exactMatches(wanted: wanted, offered: offered)
        },
        onDecide: @escaping @Sendable (NegotiationContext) async throws -> NegotiationMove = { _ in
            throw AgentModelError.unsupported
        }
    ) {
        self.descriptor = descriptor
        self.usage = usage
        self.latency = latency
        self.onInterpret = onInterpret
        self.onMatch = onMatch
        self.onDecide = onDecide
    }

    public func interpret(_ utterance: OwnerUtterance, context: InterpretationContext) async throws -> ModelResult<OwnerRules> {
        ModelResult(value: try await onInterpret(utterance, context), usage: usage, latency: latency)
    }

    public func match(wanted: [Keyword], offered: [Keyword]) async throws -> ModelResult<[KeywordMatch]> {
        ModelResult(value: try await onMatch(wanted, offered), usage: usage, latency: latency)
    }

    public func decide(_ context: NegotiationContext) async throws -> ModelResult<NegotiationMove> {
        ModelResult(value: try await onDecide(context), usage: usage, latency: latency)
    }

    public static func exactMatches(wanted: [Keyword], offered: [Keyword]) -> [KeywordMatch] {
        let offeredSet = Set(offered)
        return wanted.filter(offeredSet.contains).map { KeywordMatch(wanted: $0, offered: $0, strength: .equivalent) }
    }
}
