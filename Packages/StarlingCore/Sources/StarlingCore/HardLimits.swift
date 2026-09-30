import Foundation

/// One way a set of terms breaks the owner's limits.
public struct LimitViolation: Hashable, Sendable, CustomStringConvertible {
    public enum Reason: String, Hashable, Sendable, Codable {
        case overBudget, underMinimum, currencyMismatch, outsideAvailableTime, outsideDailyWindow, countOutOfRange, flagMismatch, avoidedKeyword
    }

    public let issue: IssueKey
    public let reason: Reason

    public init(issue: IssueKey, reason: Reason) {
        self.issue = issue
        self.reason = reason
    }

    public var description: String {
        let text = switch reason {
        case .overBudget: "over budget"
        case .underMinimum: "under minimum"
        case .currencyMismatch: "currency does not match the limit"
        case .outsideAvailableTime: "outside available time"
        case .outsideDailyWindow: "outside daily window"
        case .countOutOfRange: "count out of range"
        case .flagMismatch: "flag mismatch"
        case .avoidedKeyword: "includes an avoided keyword"
        }
        return "\(issue): \(text)"
    }
}

extension ConstraintSet {
    /// Which of `terms` break the owner's hard limits, plus any avoided
    /// keyword (avoidance counts even though preferences are soft).
    ///
    /// The model proposes; code enforces (ARCHITECTURE rule 6). Negotiation
    /// calls this before and after every model call, and the agent uses it to
    /// mark conflicts in prompts. An issue the terms do not mention is not a
    /// violation. Sorted by issue, then reason, so output is deterministic.
    public func violations(of terms: Terms, timeZone: TimeZone) -> [LimitViolation] {
        var found: [LimitViolation] = []
        for (key, list) in constraints {
            for constraint in list where constraint.strength == .hard {
                if let reason = Self.check(terms[key], rule: constraint.rule, timeZone: timeZone) {
                    found.append(LimitViolation(issue: key, reason: reason))
                }
            }
            for constraint in list {
                if case .prefers(_, let avoided) = constraint.rule,
                   case .keywords(let offered)? = terms[key],
                   !Set(offered).isDisjoint(with: avoided) {
                    found.append(LimitViolation(issue: key, reason: .avoidedKeyword))
                }
            }
        }
        return Array(Set(found)).sorted { ($0.issue, $0.reason.rawValue) < ($1.issue, $1.reason.rawValue) }
    }

    private static func check(_ value: IssueValue?, rule: Constraint.Rule, timeZone: TimeZone) -> LimitViolation.Reason? {
        switch (rule, value) {
        // An amount in another currency cannot be compared, so it cannot pass.
        case (.atMost(let limit), .amount(let amount)?):
            guard amount.currency == limit.currency else { return .currencyMismatch }
            return amount.minorUnits > limit.minorUnits ? .overBudget : nil
        case (.atLeast(let limit), .amount(let amount)?):
            guard amount.currency == limit.currency else { return .currencyMismatch }
            return amount.minorUnits < limit.minorUnits ? .underMinimum : nil
        case (.within(let windows), .slots(let slots)?):
            let fits = slots.allSatisfy { slot in
                windows.contains { $0.startMinute <= slot.startMinute && slot.endMinute <= $0.endMinute }
            }
            return fits ? nil : .outsideAvailableTime
        case (.dailyWindow(let from, let to), .slots(let slots)?):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let fits = slots.allSatisfy { slot in
                let start = calendar.dateComponents([.hour, .minute], from: slot.start)
                let minutes = (start.hour ?? 0) * 60 + (start.minute ?? 0)
                return minutes >= from && Int64(minutes) + slot.durationMinutes <= Int64(to)
            }
            return fits ? nil : .outsideDailyWindow
        case (.countBetween(let min, let max), .count(let count)?):
            return (min...max).contains(count) ? nil : .countOutOfRange
        case (.mustBe(let required), .flag(let flag)?):
            return flag == required ? nil : .flagMismatch
        default:
            return nil
        }
    }
}
