import Foundation

/// Local-only facts about an outbound message that the envelope cannot show
/// the policy. Never encoded or sent; only the `PolicyEngine` and
/// `OutboxObserver` see it (v1.1).
public struct OutboundContext: Hashable, Sendable {
    /// What a `.psi` step discloses: the provider that produced it and the
    /// typed values its set was built from. A provider that is not private
    /// reveals all of them to the peer.
    public struct PSIInputs: Hashable, Sendable {
        public let provider: PSIProviderDescriptor
        public let inputs: [IssueKey: IssueValue]

        public init(provider: PSIProviderDescriptor, inputs: [IssueKey: IssueValue]) {
            self.provider = provider
            self.inputs = inputs
        }
    }

    public let psi: PSIInputs?
    /// The friend's query an `.answer` replies to, as the service received
    /// it. With it, the policy can see that an answer only says which of
    /// the friend's own candidates work (ADR 0019).
    public let answering: Query?

    public init(psi: PSIInputs? = nil, answering: Query? = nil) {
        self.psi = psi
        self.answering = answering
    }

    public static let empty = OutboundContext()
}

extension Query {
    /// Whether `answer` only says yes or no to this query's own candidates:
    /// the same issue, and an acceptable value made only of candidates
    /// (exact members of a list, or the single candidate itself). Such an
    /// answer carries no value of the owner's, so Never does not stop it
    /// (ADR 0019 decision 4). A declined answer carries nothing at all.
    public func isAnsweredYesOrNo(by answer: Answer) -> Bool {
        guard answer.issue == issue else { return false }
        guard let acceptable = answer.acceptable else { return answer.status != .answered }
        switch (acceptable, candidates) {
        case (.keywords(let yes), .keywords(let asked)): return Set(yes).isSubset(of: asked)
        case (.slots(let yes), .slots(let asked)): return Set(yes).isSubset(of: asked)
        case (.places(let yes), .places(let asked)): return Set(yes).isSubset(of: asked)
        case (.peers(let yes), .peers(let asked)): return Set(yes).isSubset(of: asked)
        case (.amount, .amount), (.flag, .flag), (.count, .count): return acceptable == candidates
        default: return false
        }
    }
}

/// A message about to leave the device, with what the policy needs to judge it.
public struct OutboundMessage: Hashable, Sendable {
    public let envelope: Envelope
    /// The recipient's card, if a `hello` has been received.
    public let recipientCard: AgentCard?
    public let transport: TransportKind
    /// Sender-supplied local context (v1.1). Senders of `.psi` steps must
    /// fill `psi`; a policy should refuse a `.psi` step without it.
    public let context: OutboundContext

    public init(envelope: Envelope, recipientCard: AgentCard?, transport: TransportKind, context: OutboundContext = .empty) {
        self.envelope = envelope
        self.recipientCard = recipientCard
        self.transport = transport
        self.context = context
    }
}

/// One item a consent sheet shows: exactly what will leave the phone.
public struct DisclosedItem: Hashable, Sendable, Codable {
    public enum Category: String, Hashable, Sendable, Codable {
        case terms, availability, interest, psi, agentCard
    }

    public let category: Category
    public let issue: IssueKey?
    /// The value that will be sent, when there is one to show.
    public let value: IssueValue?

    public init(category: Category, issue: IssueKey?, value: IssueValue?) {
        self.category = category
        self.issue = issue
        self.value = value
    }
}

public struct Disclosure: Hashable, Sendable {
    public let recipient: PeerID
    public let recipientModel: ModelLocality?
    public let items: [DisclosedItem]
    /// The interaction the send belongs to (v2). Part of equality, so an
    /// approval remembered for one conversation never approves another
    /// skill's or chain link's identical-looking send; a retry inside the
    /// same conversation still matches (ADR 0011, review of PR #45).
    public let conversation: ConversationID?
    public let skill: SkillRef?

    public init(recipient: PeerID, recipientModel: ModelLocality?, items: [DisclosedItem], conversation: ConversationID? = nil, skill: SkillRef? = nil) {
        self.recipient = recipient
        self.recipientModel = recipientModel
        self.items = items
        self.conversation = conversation
        self.skill = skill
    }
}

public struct PolicyViolation: Error, Hashable, Sendable {
    /// Identifier of the rule that fired, for logs and tests.
    public let rule: String
    public let issue: IssueKey?

    public init(rule: String, issue: IssueKey? = nil) {
        self.rule = rule
        self.issue = issue
    }
}

public enum PolicyDecision: Hashable, Sendable {
    case allow
    case needsConsent(Disclosure)
    case deny(PolicyViolation)
}

/// Decides deterministically what may leave the device. The model never makes
/// this call (brief 3.5). `Outbox` consults it for every outbound envelope.
public protocol PolicyEngine: Sendable {
    func evaluate(_ message: OutboundMessage) async -> PolicyDecision
    /// What `message` discloses, item by item: the items a consent sheet
    /// would show. `Outbox` asks after a send the policy allowed without a
    /// sheet, so the audit lists it in the policy's own terms (ADR 0011
    /// decision 5). Throws `DisclosureUnavailable` by default.
    func disclosedItems(for message: OutboundMessage) async throws -> [DisclosedItem]
}

/// A policy engine that cannot say what a message discloses. The audit then
/// marks the send's items as unknown instead of guessing.
public struct DisclosureUnavailable: Error, Hashable, Sendable {
    public init() {}
}

extension PolicyEngine {
    public func disclosedItems(for message: OutboundMessage) async throws -> [DisclosedItem] {
        throw DisclosureUnavailable()
    }
}

public enum ConsentOutcome: Hashable, Sendable {
    case approved
    case declined
}

/// Asks the owner. The app implements this with the consent sheet.
public protocol ConsentProvider: Sendable {
    func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome
}
