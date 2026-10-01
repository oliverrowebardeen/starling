import StarlingCore

/// The app's `PolicyEngine`. `Outbox` keeps one policy for its lifetime, but
/// lane G's engine holds an immutable snapshot of the owner's rules, so this
/// rebuilds the engine whenever the rules change: saved rules, or saved
/// rules merged with the active Down intent (ADR 0141).
///
/// Until the first `update`, every send is denied, so nothing can leave the
/// phone before a saved "never share" has been loaded.
public actor RulesPolicy: PolicyEngine {
    public static let notLoadedRule = "app.rules_not_loaded"
    public static let blockedRule = "app.rules_cannot_combine"

    private let make: @Sendable (OwnerRules) -> any PolicyEngine
    private var engine: (any PolicyEngine)?
    private var isBlocked = false
    public private(set) var rules: OwnerRules?

    public init(make: @escaping @Sendable (OwnerRules) -> any PolicyEngine) {
        self.make = make
    }

    public func update(_ rules: OwnerRules) {
        isBlocked = false
        guard rules != self.rules else { return }
        self.rules = rules
        engine = make(rules)
    }

    /// Denies every send until the next `update`: the app could not work out
    /// which rules apply, and failing closed is the only safe answer.
    public func block() {
        isBlocked = true
    }

    public func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        if isBlocked { return .deny(PolicyViolation(rule: Self.blockedRule)) }
        guard let engine else { return .deny(PolicyViolation(rule: Self.notLoadedRule)) }
        return await engine.evaluate(message)
    }
}
