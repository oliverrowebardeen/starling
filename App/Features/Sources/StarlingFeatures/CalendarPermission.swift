import Foundation
import StarlingAvailability
import StarlingCore

/// Lane C's `CalendarAccess` as one of the gate's permissions (P15-C request
/// 1). `request()` runs only from the sheet's Continue, through
/// `PermissionGate`; Find a time's service only reads the status, so a
/// friend's request never raises the alert.
public struct CalendarPermissionAccess: PermissionAccess {
    public let permission = SystemPermission.calendarFullAccess
    private let access: CalendarAccess

    public init(access: CalendarAccess) {
        self.access = access
    }

    public func status() async -> PermissionStatus { Self.map(access.status) }

    public func request() async -> PermissionStatus { Self.map(await access.request()) }

    /// Write-only access cannot read busy times but can still be asked for
    /// full access, so it reads as not determined and the sheet shows.
    static func map(_ status: CalendarAccessStatus) -> PermissionStatus {
        switch status {
        case .fullAccess: .granted
        case .notDetermined, .writeOnly: .notDetermined
        case .denied, .restricted: .denied
        }
    }
}
