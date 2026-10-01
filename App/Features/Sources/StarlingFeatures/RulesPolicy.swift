import StarlingCore

/// The app's `PolicyEngine`. `Outbox` keeps one policy for its lifetime, but
/// lane G's engine holds an immutable snapshot of the owner's rules, so this
/// rebuilds the engine whenever the rules change: saved constraints with the
/// privacy topics as sharing (ADR 0014), and the on-device-only choice.
///
/// Until the first `update`, every send is denied, so nothing can leave the
/// phone before a saved "never share" has been loaded.
public actor RulesPolicy: PolicyEngine {
    public static let notLoadedRule = "app.rules_not_loaded"
    public static let blockedRule = "app.rules_cannot_combine"

    private let make: @Sendable (OwnerRules, Bool) -> any PolicyEngine
    private var engine: (any PolicyEngine)?
    private var isBlocked = false
    public private(set) var rules: OwnerRules?
    public private(set) var onlyOnDeviceAgents = false

    /// - Parameter make: Lane G's engine for one snapshot of the rules and
    ///   whether to refuse agents whose model is not on their own phone.
    public init(make: @escaping @Sendable (OwnerRules, Bool) -> any PolicyEngine) {
        self.make = make
    }

    public init(make: @escaping @Sendable (OwnerRules) -> any PolicyEngine) {
        self.make = { rules, _ in make(rules) }
    }

    public func update(_ rules: OwnerRules, onlyOnDeviceAgents: Bool = false) {
        isBlocked = false
        guard rules != self.rules || onlyOnDeviceAgents != self.onlyOnDeviceAgents || engine == nil else { return }
        self.rules = rules
        self.onlyOnDeviceAgents = onlyOnDeviceAgents
        engine = make(rules, onlyOnDeviceAgents)
    }

    /// Denies every send until the next `update`: the app could not work out
    /// which rules apply, and failing closed is the only safe answer.
    public func block() {
        isBlocked = true
    }

    /// The current engine's list of what a message discloses, for the
    /// egress log of a send allowed without a sheet (Core v2.1).
    public func disclosedItems(for message: OutboundMessage) async throws -> [DisclosedItem] {
        guard let engine else { throw DisclosureUnavailable() }
        return try await engine.disclosedItems(for: message)
    }

    public func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        if isBlocked { return .deny(PolicyViolation(rule: Self.blockedRule)) }
        guard let engine else { return .deny(PolicyViolation(rule: Self.notLoadedRule)) }
        return await engine.evaluate(message)
    }
}
