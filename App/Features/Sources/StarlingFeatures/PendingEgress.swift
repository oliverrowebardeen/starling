import Foundation
import Observation
import StarlingCore

/// Sends announced to the Outbox whose egress record is not durably on its
/// interaction yet, kept live for every audit surface (focused review of
/// PR #73). A send is marked in `willSend`, before the transport sees it,
/// and cleared only once the coordinator has saved its record. A send the
/// transport took and then failed is never recorded, so its conversation
/// stays unconfirmed for the rest of the launch, and "What left your phone"
/// never claims a topic stayed on the phone.
@MainActor
@Observable
public final class PendingEgress {
    public struct Send: Hashable, Sendable {
        public let conversation: ConversationID
        /// A skill's send, which always belongs to an interaction, even one
        /// the coordinator has not installed yet. A link-level send (a
        /// hello) has none.
        public let isSkill: Bool
        /// The skill and interaction the send named (`OutboundContext`), so
        /// its record and its audit go to that interaction even when it was
        /// sent in another conversation (a Down for... member's send in the
        /// starter's).
        public let skill: SkillRef?
        public let interaction: InteractionID?
    }

    public private(set) var messages: [MessageID: Send] = [:]

    public init() {}

    /// Conversations whose log may be missing a send right now.
    public var conversations: Set<ConversationID> { Set(messages.values.map(\.conversation)) }

    func announce(_ message: MessageID, in conversation: ConversationID, skill: SkillRef?, interaction: InteractionID?) {
        messages[message] = Send(conversation: conversation, isSkill: skill != nil, skill: skill, interaction: interaction)
    }

    /// Whether `message` is a skill's send this launch announced.
    func isSkillSend(_ message: MessageID) -> Bool { messages[message]?.isSkill == true }

    func recorded(_ message: MessageID) {
        messages[message] = nil
    }
}

/// Marks each send as pending before it leaves. Installed after lane E's
/// recorder, so a send its journal refused, which never leaves, is not
/// marked.
struct PendingEgressObserver: OutboxObserver {
    let pending: PendingEgress

    func outbox(willSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async throws {
        if case .deny = decision { return }
        await pending.announce(envelope.id, in: envelope.conversation, skill: envelope.skill, interaction: context.interaction)
    }

    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {}
}
