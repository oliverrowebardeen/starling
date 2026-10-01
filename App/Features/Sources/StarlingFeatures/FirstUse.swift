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
