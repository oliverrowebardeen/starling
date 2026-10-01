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
/// 5), and passes every send on to lane G's audit log.
///
/// For a send the owner approved on a sheet, the items are the sheet's
/// own. For a send the policy allowed without asking, `describe` computes
/// them the way the policy does (lane G's `disclosure(for:)`). Lane E's
/// observer replaces this when its package merges.
public struct EgressObserver: OutboxObserver {
    private let forward: (any OutboxObserver)?
    private let describe: @Sendable (Envelope, OutboundContext) -> [DisclosedItem]
    private let record: @MainActor @Sendable (EgressRecord, ConversationID) -> Void

    public init(
        forward: (any OutboxObserver)?,
        describe: @escaping @Sendable (Envelope, OutboundContext) -> [DisclosedItem],
        record: @escaping @MainActor @Sendable (EgressRecord, ConversationID) -> Void
    ) {
        self.forward = forward
        self.describe = describe
        self.record = record
    }

    public func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {
        await forward?.outbox(didSend: envelope, context: context, decision: decision)
        let items: [DisclosedItem] = switch decision {
        case .needsConsent(let disclosure): disclosure.items
        case .allow: describe(envelope, context)
        case .deny: []
        }
        if case .hello = envelope.body { return }
        let entry = EgressRecord(at: envelope.sentAt, recipient: envelope.recipient, items: items)
        await record(entry, envelope.conversation)
    }
}
