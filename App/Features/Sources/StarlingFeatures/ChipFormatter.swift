import Foundation
import StarlingCore

/// Short words for "Starling understood" chips in New (mockup "New"):
/// "Boba", "Tonight after 7 PM", "Nearby", "Up to $15", "Expires in 3 hrs".
/// The consent sheet and plan detail keep `ValueFormatter`'s full dates;
/// chips are for the owner's own draft, read at a glance.
public struct ChipFormatter: Sendable {
    public let values: ValueFormatter
    public let now: @Sendable () -> Date

    public init(values: ValueFormatter, now: @escaping @Sendable () -> Date = { Date() }) {
        self.values = values
        self.now = now
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = values.timeZone
        return calendar
    }

    /// One chip per rule, in issue order: activity and time first, as the
    /// mockup reads.
    public func chips(for constraints: ConstraintSet) -> [String] {
        let order: [IssueKey] = [.activity, .time, .place, .budget, .diet, .partySize]
        let issues = constraints.constraints.keys.sorted { a, b in
            (order.firstIndex(of: a) ?? order.count, a) < (order.firstIndex(of: b) ?? order.count, b)
        }
        return issues.flatMap { issue in constraints.constraints[issue]!.flatMap { chips(for: $0.rule, issue: issue) } }
    }

    public func chips(for rule: Constraint.Rule, issue: IssueKey) -> [String] {
        switch rule {
        case .prefers(let liked, let avoided):
            liked.map { $0.value.capitalizedFirstLetter } + avoided.map { "No \($0.value)" }
        case .within(let slots):
            slots.sorted().map(slot)
        case .dailyWindow(let from, let to):
            ["Between \(values.minutesOfDay(from)) and \(values.minutesOfDay(to))"]
        case .atMost(let amount):
            ["Up to \(values.money(amount))"]
        case .atLeast(let amount):
            ["At least \(values.money(amount))"]
        case .mustBe(let flag):
            ["\(values.issueName(issue)): \(flag ? "yes" : "no")"]
        case .countBetween(let min, let max):
            [issue == .partySize ? "\(min) to \(max) people" : "\(min) to \(max)"]
        }
    }

    /// "Tonight after 7 PM", "Tomorrow 10 AM to 2 PM", "Friday after 6 PM".
    public func slot(_ slot: TimeSlot) -> String {
        let day = dayWord(slot.start)
        let lastMinute = slot.end.addingTimeInterval(-60)
        let endsLate = !calendar.isDate(slot.start, inSameDayAs: lastMinute) || calendar.component(.hour, from: lastMinute) >= 23
        return endsLate ? "\(day) after \(hour(slot.start))" : "\(day) \(hour(slot.start)) to \(hour(slot.end))"
    }

    /// "Expires in 3 hrs", "Expires in 1 hr", "Expires in 45 min".
    public func expiry(_ date: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now()) / 60).rounded()))
        if minutes < 60 { return "Expires in \(minutes) min" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 24 { return hours == 1 ? "Expires in 1 hr" : "Expires in \(hours) hrs" }
        return "Expires \(dayWord(date).lowercased())"
    }

    func dayWord(_ date: Date) -> String {
        let today = calendar.startOfDay(for: now())
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return calendar.component(.hour, from: date) >= 17 ? "Tonight" : "Today"
        case 1: return "Tomorrow"
        case 2...6: return date.formatted(Date.FormatStyle(locale: values.locale, calendar: calendar, timeZone: values.timeZone).weekday(.wide))
        default: return date.formatted(Date.FormatStyle(locale: values.locale, calendar: calendar, timeZone: values.timeZone).month(.abbreviated).day())
        }
    }

    /// "7 PM", or "7:30 PM" when not on the hour.
    func hour(_ date: Date) -> String {
        let style = Date.FormatStyle(locale: values.locale, calendar: calendar, timeZone: values.timeZone)
        return calendar.component(.minute, from: date) == 0
            ? date.formatted(style.hour(.defaultDigits(amPM: .abbreviated)))
            : date.formatted(style.hour().minute())
    }
}
