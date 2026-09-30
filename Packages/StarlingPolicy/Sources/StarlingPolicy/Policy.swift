import StarlingCore

/// Stable identifiers for denial UI, tests, and diagnostic summaries.
public enum PolicyRuleID {
    public static let never = "disclosure.never"
    public static let onDeviceOnly = "recipient.on_device_only"
    public static let missingPSIContext = "disclosure.missing_psi_context"
    public static let invalidPSIContext = "disclosure.invalid_psi_context"
    public static let pairedStoreUnavailable = "recipient.paired_store_unavailable"
}

/// Deterministic egress policy for an immutable owner-rule snapshot.
/// PSI provenance comes from trusted local OutboundContext, never peer claims.
public struct DeterministicPolicyEngine: PolicyEngine {
    private let rules: [IssueKey: DisclosureRule.Action]
    private let onlyOnDeviceAgents: Bool
    private let pairedPeers: (any PairedPeerStore)?

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
                items = [Self.item(issue: answer.issue, value: value)]
            } else {
                items = []
            }
        case .psi:
            let context = try psiInputs(in: message)
            items = context.inputs.isEmpty
                ? [DisclosedItem(category: .psi, issue: nil, value: nil)]
                : context.inputs.keys.sorted().map { issue in
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
        if case .psi = message.envelope.body, let context = message.context.psi {
            // Disclosure already rejected missing or invalid PSI provenance.
            needsConsent = needsConsent || !context.provider.isPrivate || context.inputs.isEmpty
        }
        for item in disclosure.items {
            if let issue = item.issue, rules[issue] != .allowOnDevicePeers { needsConsent = true }
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

    private func psiInputs(in message: OutboundMessage) throws -> OutboundContext.PSIInputs {
        guard let context = message.context.psi else {
            throw PolicyViolation(rule: PolicyRuleID.missingPSIContext)
        }
        // Unlike Terms, the local context dictionary has no validating initializer.
        for issue in context.inputs.keys.sorted() {
            do { _ = try context.inputs[issue]!.validated() }
            catch { throw PolicyViolation(rule: PolicyRuleID.invalidPSIContext, issue: issue) }
        }
        return context
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
        let category: DisclosedItem.Category = issue == .time ? .availability : (issue == .activity || issue == .downLevel) ? .interest : .terms
        return DisclosedItem(category: category, issue: issue, value: value)
    }
}
