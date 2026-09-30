import Foundation

/// A message about to leave the device, with what the policy needs to judge it.
public struct OutboundMessage: Hashable, Sendable {
    public let envelope: Envelope
    /// The recipient's card, if a `hello` has been received.
    public let recipientCard: AgentCard?
    public let transport: TransportKind

    public init(envelope: Envelope, recipientCard: AgentCard?, transport: TransportKind) {
        self.envelope = envelope
        self.recipientCard = recipientCard
        self.transport = transport
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
