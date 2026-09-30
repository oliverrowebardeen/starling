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

    public init(psi: PSIInputs? = nil) {
        self.psi = psi
    }

    public static let empty = OutboundContext()
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
public struct DisclosedItem: Hashable, Sendable {
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

    public init(recipient: PeerID, recipientModel: ModelLocality?, items: [DisclosedItem]) {
        self.recipient = recipient
        self.recipientModel = recipientModel
        self.items = items
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
}

public enum ConsentOutcome: Hashable, Sendable {
    case approved
    case declined
}

/// Asks the owner. The app implements this with the consent sheet.
public protocol ConsentProvider: Sendable {
    func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome
}
