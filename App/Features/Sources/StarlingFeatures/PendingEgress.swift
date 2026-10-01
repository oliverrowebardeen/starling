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
    public private(set) var messages: [MessageID: ConversationID] = [:]

    public init() {}

    /// Conversations whose log may be missing a send right now.
    public var conversations: Set<ConversationID> { Set(messages.values) }

    func announce(_ message: MessageID, in conversation: ConversationID) {
        messages[message] = conversation
    }

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
        await pending.announce(envelope.id, in: envelope.conversation)
    }

    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {}
}
