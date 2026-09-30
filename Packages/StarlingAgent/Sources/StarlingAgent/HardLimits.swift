import Foundation
import StarlingCore

/// Deterministic check: which of `terms` break the owner's hard limits?
///
/// Used two ways: the decision prompt marks conflicting items so the model
/// does not have to work them out, and the bench counts limit violations in
/// what the model accepted or countered. The negotiation lane owns the real
/// enforcement; this is the Phase 0 version.
package enum HardLimits {
    package static func violations(of terms: Terms, against constraints: ConstraintSet, timeZone: TimeZone) -> [String] {
        var problems: [String] = []
        for (key, list) in constraints.constraints {
            for constraint in list where constraint.strength == .hard {
                if let problem = check(terms[key], key: key, rule: constraint.rule, timeZone: timeZone) { problems.append(problem) }
            }
            // Avoided keywords count even though preferences are soft.
            if case .prefers(_, let avoided)? = list.first(where: { if case .prefers = $0.rule { true } else { false } })?.rule,
               case .keywords(let offered)? = terms[key], !Set(offered).isDisjoint(with: avoided) {
                problems.append("\(key): includes an avoided keyword")
            }
        }
        return problems.sorted()
    }

    private static func check(_ value: IssueValue?, key: IssueKey, rule: Constraint.Rule, timeZone: TimeZone) -> String? {
        switch (rule, value) {
        case (.atMost(let limit), .amount(let amount)?):
            return amount.currency == limit.currency && amount.minorUnits > limit.minorUnits ? "\(key): over budget" : nil
        case (.atLeast(let limit), .amount(let amount)?):
            return amount.currency == limit.currency && amount.minorUnits < limit.minorUnits ? "\(key): under minimum" : nil
        case (.within(let windows), .slots(let slots)?):
            let fits = slots.allSatisfy { slot in windows.contains { $0.startMinute <= slot.startMinute && slot.endMinute <= $0.endMinute } }
            return fits ? nil : "\(key): outside available time"
        case (.dailyWindow(let from, let to), .slots(let slots)?):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let fits = slots.allSatisfy { slot in
                let start = calendar.dateComponents([.hour, .minute], from: slot.start)
                let minutes = (start.hour ?? 0) * 60 + (start.minute ?? 0)
                return minutes >= from && minutes + Int(slot.durationMinutes) <= to
            }
            return fits ? nil : "\(key): outside daily window"
        case (.countBetween(let min, let max), .count(let count)?):
            return (min...max).contains(count) ? nil : "\(key): count out of range"
        case (.mustBe(let required), .flag(let flag)?):
            return flag == required ? nil : "\(key): flag mismatch"
        default:
            return nil
        }
    }
}
