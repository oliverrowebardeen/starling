import Foundation
import StarlingCore

/// Triggers the system's Local Network alert. iOS has no API to ask for the
/// permission or read its state; the alert appears on the first local
/// network operation (TN3179), so the app performs one on purpose, at the
/// first Pair or the first request (ADR 0013, ADR 0202).
public protocol LocalNetworkPrompter: Sendable {
    func prompt() async
}

/// What iOS says about Starling's notifications.
public enum NotificationAccess: Hashable, Sendable {
    /// iOS has not asked yet.
    case notAsked
    case allowed
    /// The owner said no, here or in Settings. Only Settings can change it.
    case denied
}

/// Posts local notifications. The app implements it with UserNotifications.
public protocol PlanNotifier: Sendable {
    /// Asks the owner for permission. Returns whether alerts are allowed.
    func requestAuthorization() async -> Bool
    func post(_ notice: LifecycleNotice) async
    /// Whether iOS has asked, and what the owner answered (ADR 0260).
    func access() async -> NotificationAccess
}

extension PlanNotifier {
    /// For notifiers that cannot tell: treated as asked, so nothing re-asks.
    public func access() async -> NotificationAccess { .allowed }
}

/// A skill service that retries conversation retirements its ledger could
/// not record (lane E's Swap photos). The app calls it at launch and when it
/// comes to the foreground.
public protocol RetriesRetirements: Sendable {
    func retryRetirements() async
}
