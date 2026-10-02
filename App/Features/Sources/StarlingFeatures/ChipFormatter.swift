import Foundation
import StarlingCore

/// Short words for "Starling understood" chips in New (mockup "New"):
/// "Boba", "Tonight after 7 PM", "Nearby", "Up to $15",
/// "Friends can answer until 4:15 PM".
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
            DayRange.Hours(from: from, to: to) == .evenings
                ? ["Evenings"]
                : ["Between \(clock(minutes: from)) and \(clock(minutes: to))"]
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
        // Days, as Find a time asks: "Today to Friday".
        if slot.end.timeIntervalSince(slot.start) > 24 * 3600 {
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

    /// Until when friends can answer, by its end time, so it never reads
    /// like the plan's length (device test 2): "Friends can answer until
    /// 4:15 PM", "until tomorrow at 9 AM", "until Friday at 6 PM".
    public func answerUntil(_ date: Date) -> String {
        let today = calendar.startOfDay(for: now())
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day ?? 0
        let day: String? = switch days {
        case 0: nil
        case 1: "tomorrow"
        default: dayWord(date)
        }
        return "Friends can answer until " + (day.map { "\($0) at \(hour(date))" } ?? hour(date))
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

    /// A minute of the day as a clock time: "5 PM", "9:30 PM", "midnight".
    func clock(minutes: Int) -> String {
        guard minutes > 0, minutes < 1440,
              let date = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: minutes / 60, minute: minutes % 60))
        else { return "midnight" }
        return hour(date)
    }

    /// "7 PM", or "7:30 PM" when not on the hour.
    func hour(_ date: Date) -> String {
        let style = Date.FormatStyle(locale: values.locale, calendar: calendar, timeZone: values.timeZone)
        return calendar.component(.minute, from: date) == 0
            ? date.formatted(style.hour(.defaultDigits(amPM: .abbreviated)))
            : date.formatted(style.hour().minute())
    }
}
