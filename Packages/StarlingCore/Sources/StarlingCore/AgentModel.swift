import Foundation

/// Describes the model behind an `AgentModel`.
public struct ModelDescriptor: Hashable, Sendable, Codable {
    /// A stable identifier, for example `apple.system` or `fake.scripted`.
    public let identifier: String
    public let locality: ModelLocality
    /// Context window in tokens, read at runtime (ADR 0002). Never assume 4096.
    public let contextSize: Int

    public init(identifier: String, locality: ModelLocality, contextSize: Int) {
        self.identifier = identifier
        self.locality = locality
        self.contextSize = contextSize
    }
}

public struct TokenUsage: Hashable, Sendable, Codable {
    public let inputTokens: Int
    public let outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public var total: Int { inputTokens + outputTokens }
}

/// A model result plus the measurements the Phase 0 spike needs.
public struct ModelResult<Value: Sendable>: Sendable {
    public let value: Value
    /// Nil when the backend cannot count tokens.
    public let usage: TokenUsage?
    public let latency: Duration

    public init(value: Value, usage: TokenUsage?, latency: Duration) {
        self.value = value
        self.usage = usage
        self.latency = latency
    }
}

extension ModelResult: Equatable where Value: Equatable {}

/// Text typed or dictated by the device's owner. Never construct this from
/// anything a peer sent: peer data reaches the model only as typed values.
public struct OwnerUtterance: Hashable, Sendable {
    public let text: String

    public init(_ text: String) throws {
        guard !text.isEmpty, text.count <= ProtocolLimits.maxOwnerUtteranceCharacters else {
            throw ValidationError("OwnerUtterance", "must be 1-\(ProtocolLimits.maxOwnerUtteranceCharacters) characters")
        }
        self.text = text
    }
}

public struct InterpretationContext: Hashable, Sendable {
    public let now: Date
    public let timeZone: TimeZone
    /// Issues the caller wants filled, in priority order.
    public let issues: [IssueKey]

    public init(now: Date, timeZone: TimeZone, issues: [IssueKey]) {
        self.now = now
        self.timeZone = timeZone
        self.issues = issues
    }
}

public struct KeywordMatch: Hashable, Sendable, Codable {
    public enum Strength: String, Hashable, Sendable, Codable {
        /// Same thing ("boba" and "bubble tea").
        case equivalent
        /// One satisfies the other ("food" and "boba run").
        case satisfies
    }

    public let wanted: Keyword
    public let offered: Keyword
    public let strength: Strength

    public init(wanted: Keyword, offered: Keyword, strength: Strength) {
        self.wanted = wanted
        self.offered = offered
        self.strength = strength
    }
}

/// A compact record of one earlier round, so each round can run in a fresh
/// model session (ADR 0002).
public struct NegotiationRound: Hashable, Sendable, Codable {
    public enum Actor: String, Hashable, Sendable, Codable { case me, peer }

    public let actor: Actor
    public let kind: MessageBody.Kind
    public let terms: Terms?

    public init(actor: Actor, kind: MessageBody.Kind, terms: Terms?) {
        self.actor = actor
        self.kind = kind
        self.terms = terms
    }
}

public struct NegotiationContext: Hashable, Sendable {
    /// The peer's latest proposal.
    public let proposal: Proposal
    /// The owner's private constraints. Never sent.
    public let constraints: ConstraintSet
    public let history: [NegotiationRound]
    public let now: Date

    public init(proposal: Proposal, constraints: ConstraintSet, history: [NegotiationRound], now: Date) {
        self.proposal = proposal
        self.constraints = constraints
        self.history = history
        self.now = now
    }
}

public enum NegotiationMove: Hashable, Sendable, Codable {
    case accept
    case counter(Terms)
    case reject(Rejection.Reason)
}

public enum AgentModelError: Error, Hashable, Sendable {
    /// The model cannot run here (device not eligible, Apple Intelligence off,
    /// model still downloading). `reason` is for logs.
    case unavailable(reason: String)
    case contextWindowExceeded
    case guardrailViolation
    /// The model produced output that failed validation.
    case invalidOutput(String)
    /// Throttled or cancelled, for example while the app is in the background.
    case interrupted
    case unsupported
}

/// The jobs where a language model earns its place (brief 2.4, ADR 0009).
/// Everything else is plain logic in the negotiation layer.
///
/// Implementations own their prompts. The only peer-originated data they may
/// put in a prompt is typed and bounded: keywords, slots, amounts, flags, counts.
public protocol AgentModel: Sendable {
    var descriptor: ModelDescriptor { get }

    /// Turn the owner's own words into structured rules for review.
    func interpret(_ utterance: OwnerUtterance, context: InterpretationContext) async throws -> ModelResult<OwnerRules>

    /// Fuzzy-match what the owner wants against what a peer offers.
    func match(wanted: [Keyword], offered: [Keyword]) async throws -> ModelResult<[KeywordMatch]>

    /// Choose a response to a multi-issue proposal. Single-issue cases should
    /// not call this; plain logic handles them.
    func decide(_ context: NegotiationContext) async throws -> ModelResult<NegotiationMove>
}
