import Foundation
import StarlingCore

/// Triggers the system's Local Network alert. iOS has no API to ask for the
/// permission or read its state; the alert appears on the first local
/// network operation (TN3179), so the app performs one on purpose, at the
/// first Pair or the first request (ADR 0013, ADR 0202).
public protocol LocalNetworkPrompter: Sendable {
    func prompt() async
}

/// Posts local notifications. The app implements it with UserNotifications.
public protocol PlanNotifier: Sendable {
    /// Asks the owner for permission. Returns whether alerts are allowed.
    func requestAuthorization() async -> Bool
    func post(_ notice: LifecycleNotice) async
}

/// Records what each send disclosed on its interaction (ADR 0201 decision
/// 5), and passes every send on to lane G's audit log. `Outbox` hands over
/// the items: the consent sheet's own, or for a send the policy allowed
/// without a sheet, the policy's list. When the policy could not say, the
/// record is marked unknown, so nobody claims a topic stayed on the phone.
/// Lane E's observer replaces this when its package merges.
public struct EgressObserver: OutboxObserver {
    private let forward: (any OutboxObserver)?
    private let record: @MainActor @Sendable (EgressRecord, InteractionID?, ConversationID) -> Void

    public init(
        forward: (any OutboxObserver)?,
        record: @escaping @MainActor @Sendable (EgressRecord, InteractionID?, ConversationID) -> Void
    ) {
        self.forward = forward
        self.record = record
    }

    public func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {
        await outbox(didSend: envelope, context: context, decision: decision, disclosed: nil)
    }

    public func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async {
        await forward?.outbox(didSend: envelope, context: context, decision: decision, disclosed: disclosed)
        if case .hello = envelope.body { return }
        let entry = EgressRecord(at: envelope.sentAt, recipient: envelope.recipient, items: disclosed ?? [],
                                 message: envelope.id, itemsUnknown: disclosed == nil)
        await record(entry, context.interaction, envelope.conversation)
    }
}
