import Foundation

/// The calendar permission, for the app's pre-permission sheet and You.
///
/// The flow (ADR 0013, decision 3):
/// 1. When the owner starts Find a time and `shouldShowSheet` is true, the
///    app shows Starling's sheet with its one "Continue" button.
/// 2. "Continue" calls `request()`, which shows the system alert.
/// 3. Allow gives full access. The system's Don't Allow gives `.denied`, and
///    the skill falls back to asking the owner right away.
///
/// Nothing else in Starling asks for the permission. Skill services and
/// availability sources only read `status`, so a friend's request can never
/// raise the system alert (ARCHITECTURE rule 8).
public struct CalendarAccess: Sendable {
    /// The Info.plist key for reading events on iOS 17 and later. Without it,
    /// or with only the older `NSCalendarsUsageDescription`, iOS denies the
    /// request without asking.
    public static let usageDescriptionKey = "NSCalendarsFullAccessUsageDescription"

    /// The purpose string the system alert shows, specific to Find a time
    /// (ADR 0013, decision 6).
    public static let purposeString =
        "Starling checks when you're busy so friends' agents can find a time without asking you. Event details stay on your iPhone."

    private let store: any CalendarStore

    public init(store: any CalendarStore) {
        self.store = store
    }

    public var status: CalendarAccessStatus { store.accessStatus() }

    /// Whether to show Starling's one-button sheet before the system alert:
    /// only when the alert can still appear. After a denial the sheet would
    /// lead nowhere, so the skill asks the owner instead.
    public var shouldShowSheet: Bool { status.canAsk }

    /// Shows the system alert. Call it only from the sheet's "Continue"
    /// button. Returns the status afterwards; an error reads as the status
    /// the store reports, which after a failed request is not full access.
    @discardableResult
    public func request() async -> CalendarAccessStatus {
        guard status.canAsk else { return status }
        _ = try? await store.requestFullAccess()
        return status
    }
}

/// The owner's choice in You › Skills for Find a time: "Use my calendar" or
/// "Just ask me". Stored by the app; read each time availability is needed.
public enum CalendarUse: String, Hashable, Sendable, Codable, CaseIterable {
    case useMyCalendar
    case justAskMe
}
