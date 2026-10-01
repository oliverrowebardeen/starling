import Foundation
import StarlingCore

/// Fixed times: Monday 2026-10-05 00:00 UTC and offsets in hours from it.
enum T {
    static let utc = TimeZone(identifier: "UTC")!
    static let monday = Date(timeIntervalSince1970: 1_791_158_400)

    static func at(_ hours: Double) -> Date { monday.addingTimeInterval(hours * 3600) }

    static func slot(_ fromHours: Double, _ toHours: Double) -> TimeSlot {
        try! TimeSlot(start: at(fromHours), end: at(toHours))
    }
}
