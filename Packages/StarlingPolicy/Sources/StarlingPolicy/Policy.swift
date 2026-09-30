import Foundation
import StarlingCore

/// Stable identifiers for denial UI, tests, and diagnostic summaries.
public enum PolicyRuleID {
    public static let never = "disclosure.never"
    public static let onDeviceOnly = "recipient.on_device_only"
    public static let missingQueryContext = "disclosure.missing_query_context"
    public static let missingPSIContext = "disclosure.missing_psi_context"
    public static let pairedStoreUnavailable = "recipient.paired_store_unavailable"
}

public enum PolicyContextError: Error, Hashable, Sendable {
    case notAQuery
    case conflictingRegistration
    case capacityExceeded
}

/// Deterministic egress policy. Create one per local identity and rule snapshot.
/// Register context from Inbox and the local PSI provider, never from peer claims.
public actor DeterministicPolicyEngine: PolicyEngine {
    public static let maxContextEntries = 256

    private struct QueryKey: Hashable {
        let local: PeerID
        let peer: PeerID
        let conversation: ConversationID
        let query: MessageID
    }

    private struct PSIKey: Hashable {
        let peer: PeerID
        let conversation: ConversationID
        let session: UUID
        let step: UInt8
    }

    private struct PSIContext: Hashable {
        let frame: PSIFrame
        let provider: PSIProviderDescriptor
        let inputs: Terms
    }

    private let rules: [IssueKey: DisclosureRule.Action]
    private let onlyOnDeviceAgents: Bool
    private let pairedPeers: (any PairedPeerStore)?
    private var queries: [QueryKey: IssueKey] = [:]
    private var psiSteps: [PSIKey: PSIContext] = [:]

    public init(
        ownerRules: OwnerRules = .empty,
        onlyOnDeviceAgents: Bool = false,
        pairedPeers: (any PairedPeerStore)? = nil
    ) {
        rules = Dictionary(ownerRules.disclosure.map { ($0.issue, $0.action) }, uniquingKeysWith: { a, b in
            if a == .never || b == .never { return .never }
            if a == .askEachTime || b == .askEachTime { return .askEachTime }
            return .allowOnDevicePeers
        })
        self.onlyOnDeviceAgents = onlyOnDeviceAgents
        self.pairedPeers = pairedPeers
    }

    /// Call only for a query accepted by Inbox over the authenticated channel.
    /// Keep the issue, not the peer's candidate values. Re-registration is idempotent.
    public func registerReceivedQuery(_ envelope: Envelope) throws {
        guard case .query(let query) = envelope.body else { throw PolicyContextError.notAQuery }
        let key = QueryKey(local: envelope.recipient, peer: envelope.sender,
                           conversation: envelope.conversation, query: envelope.id)
        if let existing = queries[key] {
            guard existing == query.issue else { throw PolicyContextError.conflictingRegistration }
            return
        }
        try checkCapacity()
        queries[key] = query.issue
    }

    /// Register every outgoing step with the actual local provider's descriptor.
    /// `inputs` must describe the complete semantic input set, including issues
    /// protected by owner rules. A private provider hides values, not the issue.
    /// Exact frame binding prevents changed payloads from reusing registration.
    public func registerPSIStep(
        _ frame: PSIFrame, to recipient: PeerID, conversation: ConversationID,
        provider: PSIProviderDescriptor, inputs: Terms
    ) throws {
        let key = PSIKey(peer: recipient, conversation: conversation, session: frame.session, step: frame.step)
        let context = PSIContext(frame: frame, provider: provider, inputs: inputs)
        if let existing = psiSteps[key] {
            guard existing == context else { throw PolicyContextError.conflictingRegistration }
            return
        }
        try checkCapacity()
        psiSteps[key] = context
    }

    /// Release bounded context when a negotiation ends or is abandoned.
    public func forgetConversation(_ conversation: ConversationID, with peer: PeerID) {
        queries = queries.filter { $0.key.conversation != conversation || $0.key.peer != peer }
        psiSteps = psiSteps.filter { $0.key.conversation != conversation || $0.key.peer != peer }
    }

    /// Computes every semantic issue and value leaving the device. Protocol
    /// metadata uses category markers when Core has no corresponding IssueValue.
    /// It never derives an answer's issue from its value's shape.
    public func disclosure(for message: OutboundMessage) throws -> Disclosure {
        let envelope = message.envelope
        let items: [DisclosedItem]
        switch envelope.body {
        case .hello:
            items = [DisclosedItem(category: .agentCard, issue: nil, value: nil)]
        case .propose(let proposal), .counter(let proposal):
            items = Self.items(for: proposal.terms)
        case .accept(let acceptance):
            items = Self.items(for: acceptance.terms)
        case .reject:
            items = []
        case .query(let query):
            items = [Self.item(issue: query.issue, value: query.candidates)]
        case .answer(let answer):
            if let value = answer.acceptable {
                let key = QueryKey(local: envelope.sender, peer: envelope.recipient,
                                   conversation: envelope.conversation, query: answer.query)
                guard let issue = queries[key] else {
                    throw PolicyViolation(rule: PolicyRuleID.missingQueryContext)
                }
                items = [Self.item(issue: issue, value: value)]
            } else {
                items = []
            }
        case .psi(let frame):
            let context = try psiContext(frame, envelope: envelope)
            items = context.inputs.values.isEmpty
                ? [DisclosedItem(category: .psi, issue: nil, value: nil)]
                : context.inputs.values.keys.sorted().map { issue in
                    DisclosedItem(category: .psi, issue: issue,
                                  value: context.provider.isPrivate ? nil : context.inputs[issue])
                }
        }
        return Disclosure(recipient: envelope.recipient, recipientModel: message.recipientCard?.model, items: items)
    }

    public func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        // Hello is the bootstrap: it carries a card, never owner issue values.
        if case .hello = message.envelope.body { return .allow }
        let onDevice = Self.isOnDevice(message.recipientCard?.model)
        if onlyOnDeviceAgents && !onDevice {
            return .deny(PolicyViolation(rule: PolicyRuleID.onDeviceOnly))
        }

        let disclosure: Disclosure
        do {
            disclosure = try self.disclosure(for: message)
        } catch let violation as PolicyViolation {
            return .deny(violation)
        } catch {
            // All disclosure failures above are PolicyViolation; never allow
            // egress if a future context validation adds a different error.
            return .deny(PolicyViolation(rule: "disclosure.unavailable"))
        }
        for item in disclosure.items {
            if let issue = item.issue, rules[issue] == .never {
                return .deny(PolicyViolation(rule: PolicyRuleID.never, issue: issue))
            }
        }

        var needsConsent = !onDevice
        if case .psi(let frame) = message.envelope.body {
            // Already checked by disclosure; no suspension or mutation in between.
            guard let context = try? psiContext(frame, envelope: message.envelope) else {
                return .deny(PolicyViolation(rule: PolicyRuleID.missingPSIContext))
            }
            needsConsent = needsConsent || !context.provider.isPrivate || context.inputs.values.isEmpty
        }
        for item in disclosure.items where item.issue != nil {
            if rules[item.issue!] != .allowOnDevicePeers { needsConsent = true }
        }
        if needsConsent { return .needsConsent(disclosure) }

        // A card is not proof of pairing. Automatic sharing requires the store.
        if disclosure.items.contains(where: { $0.issue != nil }) {
            guard let pairedPeers else { return .needsConsent(disclosure) }
            do {
                guard let peer = try await pairedPeers.peer(for: message.envelope.recipient),
                      peer.id == message.envelope.recipient else { return .needsConsent(disclosure) }
            } catch {
                return .deny(PolicyViolation(rule: PolicyRuleID.pairedStoreUnavailable))
            }
        }
        return .allow
    }

    private func psiContext(_ frame: PSIFrame, envelope: Envelope) throws -> PSIContext {
        let key = PSIKey(peer: envelope.recipient, conversation: envelope.conversation,
                         session: frame.session, step: frame.step)
        guard let context = psiSteps[key], context.frame == frame else {
            throw PolicyViolation(rule: PolicyRuleID.missingPSIContext)
        }
        return context
    }

    private func checkCapacity() throws {
        guard queries.count + psiSteps.count < Self.maxContextEntries else {
            throw PolicyContextError.capacityExceeded
        }
    }

    private static func isOnDevice(_ locality: ModelLocality?) -> Bool {
        switch locality {
        case .some(.onDevice), .some(.none): true
        default: false
        }
    }

    private static func items(for terms: Terms) -> [DisclosedItem] {
        terms.values.keys.sorted().map { item(issue: $0, value: terms.values[$0]!) }
    }

    private static func item(issue: IssueKey, value: IssueValue) -> DisclosedItem {
        let category: DisclosedItem.Category = issue == .time ? .availability : issue == .activity ? .interest : .terms
        return DisclosedItem(category: category, issue: issue, value: value)
    }
}
