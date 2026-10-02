import Foundation
import StarlingCore

/// Shared values. Times are hours on 2026-10-02 UTC, so `T.slot(19, 21)` is
/// 19:00 to 21:00 that day.
enum T {
    /// 2026-10-02 19:00:00 UTC, on a 30-minute boundary.
    static let now = Date(timeIntervalSince1970: 1_790_967_600)
    private static let midnight = now.addingTimeInterval(-19 * 3600)
    static let utc = TimeZone(identifier: "UTC")!

    static func at(_ hour: Double) -> Date { midnight.addingTimeInterval(hour * 3600) }
    static func slot(_ from: Double, _ to: Double) -> TimeSlot { try! TimeSlot(start: at(from), end: at(to)) }
    static func keyword(_ text: String) -> Keyword { try! Keyword(text) }
    static func usd(_ dollars: Int64) -> MoneyAmount { try! MoneyAmount(minorUnits: dollars * 100) }

    static func rules(time: [TimeSlot]? = nil, liked: [String], avoided: [String] = [], maxBudget: Int64? = nil) throws -> OwnerRules {
        var rules: [IssueKey: [Constraint]] = [:]
        if let time { rules[.time] = [try Constraint(.within(time))] }
        rules[.activity] = [try Constraint(.prefers(liked: liked.map(keyword), avoided: avoided.map(keyword)), strength: .soft)]
        if let maxBudget { rules[.budget] = [try Constraint(.atMost(usd(maxBudget)))] }
        return OwnerRules(constraints: try ConstraintSet(rules))
    }
}
