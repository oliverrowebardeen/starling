import Foundation
import StarlingCore

// Plain mirrors of the @Generable outputs. Mapping from these to Core types is
// where model output gets validated, and it is testable without a model.

package struct RawMove: Hashable, Sendable {
    package enum Kind: Hashable, Sendable { case accept, counter, reject }
    package var kind: Kind
    package var timeOption: Int?
    package var activityOption: Int?
    package var budgetDollars: Int?

    package init(kind: Kind, timeOption: Int? = nil, activityOption: Int? = nil, budgetDollars: Int? = nil) {
        self.kind = kind
        self.timeOption = timeOption
        self.activityOption = activityOption
        self.budgetDollars = budgetDollars
    }
}

package struct RawRules: Hashable, Sendable {
    package enum Shareable: Hashable, Sendable { case location, schedule, budget }
    package enum Day: Hashable, Sendable {
        /// Days from today.
        case relative(Int)
        /// Gregorian weekday, 1 = Sunday. Resolves to the next such day, today included.
        case weekday(Int)
    }
    /// A named part of the day ("tonight", "morning"), used for hours the
    /// owner did not state as clock times.
    package enum PartOfDay: Hashable, Sendable {
        case morning, lunch, afternoon, evening

        /// Start and end hours in the local wall clock.
        package var hours: (from: Int, to: Int) {
            switch self {
            case .morning: (8, 12)
            case .lunch: (11, 14)
            case .afternoon: (12, 17)
            case .evening: (18, 24)
            }
        }
    }
    package var day: Day?
    package var partOfDay: PartOfDay?
    package var earliestHour: Int?
    package var latestHour: Int?
    package var wants: [String]
    package var avoids: [String]
    package var maxDollars: Int?
    package var neverShare: [Shareable]

    package init(day: Day? = nil, partOfDay: PartOfDay? = nil, earliestHour: Int? = nil, latestHour: Int? = nil, wants: [String] = [], avoids: [String] = [], maxDollars: Int? = nil, neverShare: [Shareable] = []) {
        self.day = day
        self.partOfDay = partOfDay
        self.earliestHour = earliestHour
        self.latestHour = latestHour
        self.wants = wants
        self.avoids = avoids
        self.maxDollars = maxDollars
        self.neverShare = neverShare
    }
}

package enum OutputMapping {
    /// Maps a move. Option numbers are 1-based, as rendered in the prompt.
    package static func move(_ raw: RawMove, prompt: DecisionPrompt, proposal: Proposal) throws -> NegotiationMove {
        switch raw.kind {
        case .accept: return .accept
        case .reject: return .reject(.noOverlap)
        case .counter:
            var values = proposal.terms.values
            var changed = false
            if let option = raw.timeOption {
                values[.time] = .slots([try pick(option, from: prompt.timeOptions, what: "time")])
                changed = true
            }
            if let option = raw.activityOption {
                values[.activity] = .keywords([try pick(option, from: prompt.activityOptions, what: "activity")])
                changed = true
            }
            if let dollars = raw.budgetDollars {
                guard let amount = money(dollars: dollars) else {
                    throw AgentModelError.invalidOutput("budget \(dollars) out of range")
                }
                values[.budget] = .amount(amount)
                changed = true
            }
            guard changed else { throw AgentModelError.invalidOutput("counter changes nothing") }
            do {
                return .counter(try Terms(values))
            } catch {
                throw AgentModelError.invalidOutput("counter terms invalid: \(error)")
            }
        }
    }

    /// Maps interpreted rules. Invalid keywords are dropped rather than
    /// failing the whole interpretation; the owner reviews the result.
    package static func rules(_ raw: RawRules, context: InterpretationContext) throws -> OwnerRules {
        var constraints: [IssueKey: [Constraint]] = [:]

        // Stated clock hours win over a named part of the day, and a stated
        // start with no end is open-ended ("free after 3"). Clamping first
        // keeps every later computation in range, whatever the model produced.
        let stated = raw.earliestHour != nil || raw.latestHour != nil
        let earliest = (stated ? raw.earliestHour : raw.partOfDay?.hours.from).map { min(max($0, 0), 23) }
        let latest = (stated ? raw.latestHour : raw.partOfDay?.hours.to).map { min(max($0, 1), 24) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        if let day = raw.day.flatMap({ Self.dayOffset($0, now: context.now, calendar: calendar) }) {
            let midnight = calendar.startOfDay(for: context.now)
            // A window that ends before it starts keeps the start and runs
            // to midnight, so the day the owner named is not lost with it.
            let startHour = earliest ?? 0
            let endHour = latest.flatMap { $0 > startHour ? $0 : nil } ?? 24
            if let dayStart = calendar.date(byAdding: .day, value: day, to: midnight),
               let from = wallClock(hour: startHour, on: dayStart, calendar: calendar),
               let to = wallClock(hour: endHour, on: dayStart, calendar: calendar),
               to > from, let slot = try? TimeSlot(start: from, end: to) {
                constraints[.time, default: []].append(try Constraint(.within([slot])))
            }
        } else if earliest != nil || latest != nil {
            let from = (earliest ?? 0) * 60
            let to = (latest ?? 24) * 60
            if from < to { constraints[.time, default: []].append(try Constraint(.dailyWindow(from: from, to: to))) }
        }

        let liked = keywords(raw.wants)
        let avoided = keywords(raw.avoids).filter { !liked.contains($0) }
        if !liked.isEmpty || !avoided.isEmpty {
            constraints[.activity] = [try Constraint(.prefers(liked: liked, avoided: avoided), strength: .soft)]
        }

        // Zero means "no limit" to the model ("no budget limit" came back as
        // $0 in the labeled set), so it is dropped rather than enforced.
        if let dollars = raw.maxDollars, dollars > 0, let amount = money(dollars: dollars) {
            constraints[.budget] = [try Constraint(.atMost(amount))]
        }

        let disclosure = Set(raw.neverShare).sorted { "\($0)" < "\($1)" }.map { field -> DisclosureRule in
            switch field {
            case .location: DisclosureRule(issue: .place, action: .never)
            case .schedule: DisclosureRule(issue: .time, action: .never)
            case .budget: DisclosureRule(issue: .budget, action: .never)
            }
        }
        return OwnerRules(constraints: try ConstraintSet(constraints), disclosure: disclosure)
    }

    static func dayOffset(_ day: RawRules.Day, now: Date, calendar: Calendar) -> Int? {
        switch day {
        case .relative(let offset): return (0...6).contains(offset) ? offset : nil
        case .weekday(let weekday):
            guard (1...7).contains(weekday) else { return nil }
            return (weekday - calendar.component(.weekday, from: now) + 7) % 7
        }
    }

    /// A 1-based option number from the model, range-checked before any
    /// arithmetic so `Int.min` cannot overflow.
    static func pick<T>(_ number: Int, from options: [T], what: String) throws -> T {
        guard number >= 1, number <= options.count else {
            throw AgentModelError.invalidOutput("\(what) option \(number) not offered")
        }
        return options[number - 1]
    }

    /// Whole dollars from the model, range-checked before multiplying.
    static func money(dollars: Int) -> MoneyAmount? {
        guard dollars >= 0, Int64(dollars) <= ProtocolLimits.maxMoneyMinorUnits / 100 else { return nil }
        return try? MoneyAmount(minorUnits: Int64(dollars) * 100)
    }

    /// The instant a local clock shows `hour`:00 on `dayStart`'s date, with 24
    /// meaning the next midnight. Uses calendar components, not elapsed
    /// seconds, so daylight-saving days come out right.
    package static func wallClock(hour: Int, on dayStart: Date, calendar: Calendar) -> Date? {
        if hour == 24 {
            return calendar.date(byAdding: .day, value: 1, to: dayStart).map { calendar.startOfDay(for: $0) }
        }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayStart)
    }

    private static func keywords(_ strings: [String]) -> [Keyword] {
        var seen = Set<Keyword>()
        return strings.compactMap { try? Keyword($0) }.filter { seen.insert($0).inserted }.prefix(ProtocolLimits.maxKeywordsPerValue).map { $0 }
    }
}
