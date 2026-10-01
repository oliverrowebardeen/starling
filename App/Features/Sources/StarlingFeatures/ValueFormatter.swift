import Foundation
import StarlingCore

/// One labeled line in a list: a rule, a term, or an item on the consent sheet.
public struct DisplayLine: Hashable, Sendable {
    public let title: String
    public let detail: String?

    public init(title: String, detail: String?) {
        self.title = title
        self.detail = detail
    }
}

/// Turns StarlingCore values into the words the owner sees. Every screen that
/// shows rules, terms, or a disclosure uses this, so the consent sheet and the
/// match list describe the same value the same way.
public struct ValueFormatter: Sendable {
    public let timeZone: TimeZone
    public let locale: Locale
    /// "Now", for deciding when a date needs its year.
    private let referenceDate: @Sendable () -> Date
    /// The owner's name for a paired friend, for roster values.
    private let peerName: @Sendable (PeerID) -> String?

    public init(
        timeZone: TimeZone = .current,
        locale: Locale = .current,
        referenceDate: @escaping @Sendable () -> Date = { Date() },
        peerName: @escaping @Sendable (PeerID) -> String? = { _ in nil }
    ) {
        self.timeZone = timeZone
        self.locale = locale
        self.referenceDate = referenceDate
        self.peerName = peerName
    }

    // MARK: Issues

    public func issueName(_ key: IssueKey) -> String {
        switch key {
        case .time: "Time"
        case .activity: "Activity"
        case .budget: "Budget"
        case .place: "Place"
        case .diet: "Diet"
        case .partySize: "Group size"
        default:
            key.rawValue.replacingOccurrences(of: "_", with: " ").capitalizedFirstLetter
        }
    }

    // MARK: Values

    public func value(_ value: IssueValue) -> String {
        switch value {
        case .slots(let slots): slots.isEmpty ? "No times" : slots.sorted().map(slot).joined(separator: ", ")
        case .keywords(let keywords): keywords.isEmpty ? "Nothing" : keywords.map(\.value).joined(separator: ", ")
        case .amount(let amount): money(amount)
        case .flag(let flag): flag ? "Yes" : "No"
        case .count(let count): String(count)
        case .places(let places): places.map(\.name.rawValue).joined(separator: ", ")
        case .peers(let peers): peers.map { peerName($0) ?? "someone you haven't paired with (\($0.short))" }.joined(separator: ", ")
        }
    }

    public func money(_ amount: MoneyAmount) -> String {
        let digits = Self.fractionDigits(for: amount.currency)
        let major = Decimal(amount.minorUnits) / pow(10, digits)
        return major.formatted(.currency(code: amount.currency).locale(locale).precision(.fractionLength(digits)))
    }

    /// "Tue, Sep 29, 7:00 PM to 11:00 PM", with the end's date too when the
    /// slot crosses midnight, and the year when it is not this year. Slots
    /// are absolute times, so the date is always shown: two slots a week
    /// apart must never read the same.
    public func slot(_ slot: TimeSlot) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone)
        let thisYear = calendar.component(.year, from: referenceDate())
        func day(_ date: Date) -> String {
            let style = base.weekday(.abbreviated).month(.abbreviated).day()
            return date.formatted(calendar.component(.year, from: date) == thisYear ? style : style.year())
        }
        let time = base.hour().minute()
        let start = "\(day(slot.start)), \(slot.start.formatted(time))"
        let sameDay = calendar.isDate(slot.start, inSameDayAs: slot.end.addingTimeInterval(-1))
        let end = sameDay ? slot.end.formatted(time) : "\(day(slot.end)), \(slot.end.formatted(time))"
        return "\(start) to \(end)"
    }

    /// Minutes after local midnight, `0...1440`.
    public func minutesOfDay(_ minutes: Int) -> String {
        guard minutes > 0, minutes < 1440 else { return "midnight" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: minutes / 60, minute: minutes % 60))!
        return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: timeZone).hour().minute())
    }

    // MARK: Rules

    public func rule(_ rule: Constraint.Rule) -> String {
        switch rule {
        case .within(let slots):
            "Only \(value(.slots(slots)))"
        case .dailyWindow(let from, let to):
            "Between \(minutesOfDay(from)) and \(minutesOfDay(to)) each day"
        case .prefers(let liked, let avoided):
            [
                liked.isEmpty ? nil : "Likes \(liked.map(\.value).joined(separator: ", ")).",
                avoided.isEmpty ? nil : "Avoids \(avoided.map(\.value).joined(separator: ", ")).",
            ].compactMap(\.self).joined(separator: " ")
        case .atMost(let amount):
            "At most \(money(amount))"
        case .atLeast(let amount):
            "At least \(money(amount))"
        case .mustBe(let flag):
            "Must be \(flag ? "yes" : "no")"
        case .countBetween(let min, let max):
            "Between \(min) and \(max)"
        }
    }

    public func constraint(_ constraint: Constraint) -> String {
        constraint.strength == .soft ? "\(rule(constraint.rule)) (flexible)" : rule(constraint.rule)
    }

    public func disclosureAction(_ action: DisclosureRule.Action) -> String {
        switch action {
        case .never: "Never share"
        case .askEachTime: "Ask me each time"
        case .allowOnDevicePeers: "Share with on-device agents without asking"
        }
    }

    // MARK: Consent

    /// What a peer's agent card claims. Starling cannot verify the claim yet
    /// (brief open question 4), so the wording says who is claiming it.
    public func locality(_ locality: ModelLocality) -> String {
        switch locality {
        case .onDevice: "Says its model runs on their iPhone"
        case .privateCloudCompute: "Says its model runs in Apple Private Cloud Compute"
        case .thirdPartyCloud(let provider): "Says its model runs on a cloud service (\(provider))"
        case .none: "Says it uses no language model"
        }
    }

    public func disclosedItem(_ item: DisclosedItem) -> DisplayLine {
        let detail = item.value.map(value)
        switch item.category {
        case .terms:
            return DisplayLine(title: item.issue.map(issueName) ?? "Plan details", detail: detail)
        case .availability:
            return DisplayLine(title: "Your free times", detail: detail)
        case .interest:
            return DisplayLine(title: "Whether you're interested", detail: detail)
        case .psi:
            return DisplayLine(title: "Matching step over your free times", detail: detail)
        case .agentCard:
            return DisplayLine(title: "Your agent card", detail: detail ?? "Where your model runs and what your agent can do")
        }
    }

    public func terms(_ terms: Terms) -> [DisplayLine] {
        terms.values.keys.sorted().map { DisplayLine(title: issueName($0), detail: value(terms.values[$0]!)) }
    }

    // MARK: Helpers

    static func fractionDigits(for currency: String) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.maximumFractionDigits
    }
}

extension String {
    var capitalizedFirstLetter: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
