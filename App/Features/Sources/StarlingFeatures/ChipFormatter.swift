import Foundation
import StarlingCore

/// Short words for "Starling understood" chips in New (mockup "New"):
/// "Boba", "Tonight after 7 PM", "Nearby", "Up to $15", "Open for 3 hrs".
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
    /// mockup reads. With `typed`, the owner's words, a keyword chip shows
    /// exactly as the owner typed it ("IKEA trip", "movie night").
    public func chips(for constraints: ConstraintSet, typed: String? = nil) -> [String] {
        orderedIssues(constraints).flatMap { issue in constraints.constraints[issue]!.flatMap { chips(for: $0.rule, issue: issue, typed: typed) } }
    }

    /// The issues in chip order: what, when, where, then the rest.
    public func orderedIssues(_ constraints: ConstraintSet) -> [IssueKey] {
        let order: [IssueKey] = [.activity, .time, .place, .budget, .diet, .partySize]
        return constraints.constraints.keys.sorted { a, b in
            (order.firstIndex(of: a) ?? order.count, a) < (order.firstIndex(of: b) ?? order.count, b)
        }
    }

    public func chips(for rule: Constraint.Rule, issue: IssueKey, typed: String? = nil) -> [String] {
        switch rule {
        case .prefers(let liked, let avoided):
            liked.map { Self.spelling(of: $0, in: typed) ?? $0.value.capitalizedFirstLetter }
                + avoided.map { "No \(Self.spelling(of: $0, in: typed) ?? $0.value)" }
        case .within(let slots):
            slots.sorted().map(slot)
        case .dailyWindow(let from, let to):
            from == DayRange.evenings.from && to == DayRange.evenings.to
                ? ["Evenings"]
                : ["Between \(values.minutesOfDay(from)) and \(values.minutesOfDay(to))"]
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

    /// How the owner typed `keyword`: the run of words in `typed` that it
    /// is, in the owner's spelling and casing, or nil when there is none
    /// (lane B's grounding makes every keyword chip such a run, ADR 0212).
    /// A keyword is stored lowercased, because peers compare it, so the
    /// owner's casing comes from what they typed.
    public static func spelling(of keyword: Keyword, in typed: String?) -> String? {
        guard let typed else { return nil }
        let words = typed.split { !($0.isLetter || $0.isNumber || "'’-&$".contains($0)) }.map(String.init)
        let wanted = keyword.value.split(separator: " ").map(String.init)
        guard !wanted.isEmpty, wanted.count <= words.count else { return nil }
        for start in 0...(words.count - wanted.count) {
            let run = Array(words[start..<start + wanted.count])
            if run.map({ $0.lowercased() }) == wanted { return run.joined(separator: " ") }
        }
        return nil
    }

    /// "Tonight after 7 PM", "Tomorrow 10 AM to 2 PM", "Friday after 6 PM".
    public func slot(_ slot: TimeSlot) -> String {
        // Whole days, as Find a time asks: "Today to Friday".
        if calendar.startOfDay(for: slot.start) == slot.start, calendar.startOfDay(for: slot.end) == slot.end,
           slot.end.timeIntervalSince(slot.start) > 24 * 3600 {
            return "\(dayWord(slot.start)) to \(dayWord(slot.end.addingTimeInterval(-60)))"
        }
        let day = dayWord(slot.start)
        let lastMinute = slot.end.addingTimeInterval(-60)
        let endsLate = !calendar.isDate(slot.start, inSameDayAs: lastMinute) || calendar.component(.hour, from: lastMinute) >= 23
        return endsLate ? "\(day) after \(hour(slot.start))" : "\(day) \(hour(slot.start)) to \(hour(slot.end))"
    }

    /// When something starts: "Tonight at 8:30 PM", "Friday at 6 PM".
    public func start(_ slot: TimeSlot) -> String {
        "\(dayWord(slot.start)) at \(hour(slot.start))"
    }

    /// How long friends can answer: "Open for 3 hrs", "Open for 1 hr",
    /// "Open for 45 min", "Open until Friday".
    public func open(_ date: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now()) / 60).rounded()))
        if minutes < 60 { return "Open for \(minutes) min" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 24 { return hours == 1 ? "Open for 1 hr" : "Open for \(hours) hrs" }
        let day = dayWord(date)
        return "Open until \(["Today", "Tonight", "Tomorrow"].contains(day) ? day.lowercased() : day)"
    }

    public func dayWord(_ date: Date) -> String {
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
