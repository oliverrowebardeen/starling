import Foundation
import StarlingCore

/// Makes "every envelope of a link carries `chainedFrom`" a rule the egress
/// path enforces, not a convention each skill must remember (ADR 0240).
///
/// Wraps the app's policy. For a conversation that belongs to an owner
/// chain link, an envelope whose `chainedFrom` is missing or names another
/// conversation is denied before the wrapped policy or any consent sheet
/// sees it. Everything else goes to the wrapped policy unchanged, so the
/// owner's privacy topics still decide egress. Deterministic: it reads only
/// the envelope and the stored `ChainLink`.
public struct ChainedFromPolicy: PolicyEngine {
    /// The envelope of a chain link does not name the link's parent.
    public static let mismatchRule = "chain.chained_from_mismatch"
    /// The interaction store failed, so the link could not be checked.
    public static let storeUnavailableRule = "chain.store_unavailable"

    private let base: any PolicyEngine
    private let store: any InteractionStore

    public init(wrapping base: any PolicyEngine, store: any InteractionStore) {
        self.base = base
        self.store = store
    }

    public func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        let envelope = message.envelope
        let link: ChainLink?
        do {
            link = try await store.interaction(conversation: envelope.conversation)?.chain
        } catch {
            return .deny(PolicyViolation(rule: Self.storeUnavailableRule))
        }
        if let link, envelope.chainedFrom != link.parentConversation {
            return .deny(PolicyViolation(rule: Self.mismatchRule))
        }
        return await base.evaluate(message)
    }

    /// The wrapped policy's own list. Without this, the protocol's default
    /// would throw, and the audit would mark every send allowed without a
    /// sheet as unknown.
    public func disclosedItems(for message: OutboundMessage) async throws -> [DisclosedItem] {
        try await base.disclosedItems(for: message)
    }
}
