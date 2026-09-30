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
    package var day: Day?
    package var earliestHour: Int?
    package var latestHour: Int?
    package var wants: [String]
    package var avoids: [String]
    package var maxDollars: Int?
    package var neverShare: [Shareable]

    package init(day: Day? = nil, earliestHour: Int? = nil, latestHour: Int? = nil, wants: [String] = [], avoids: [String] = [], maxDollars: Int? = nil, neverShare: [Shareable] = []) {
        self.day = day
        self.earliestHour = earliestHour
        self.latestHour = latestHour
        self.wants = wants
        self.avoids = avoids
        self.maxDollars = maxDollars
        self.neverShare = neverShare
    }
}

package struct RawMatch: Hashable, Sendable {
    package var want: Int
    package var offer: Int
    package var same: Bool

    package init(want: Int, offer: Int, same: Bool) {
        self.want = want
        self.offer = offer
        self.same = same
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

        // Clamping first keeps every later computation in range, whatever
        // the model produced.
        let earliest = raw.earliestHour.map { min(max($0, 0), 23) }
        let latest = raw.latestHour.map { min(max($0, 1), 24) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        if let day = raw.day.flatMap({ Self.dayOffset($0, now: context.now, calendar: calendar) }) {
            let midnight = calendar.startOfDay(for: context.now)
            if let dayStart = calendar.date(byAdding: .day, value: day, to: midnight),
               let from = wallClock(hour: earliest ?? 0, on: dayStart, calendar: calendar),
               let to = wallClock(hour: latest ?? 24, on: dayStart, calendar: calendar),
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

        if let dollars = raw.maxDollars, let amount = money(dollars: dollars) {
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

    package static func matches(_ raw: [RawMatch], wanted: [Keyword], offered: [Keyword]) throws -> [KeywordMatch] {
        var seen = Set<[Int]>()
        return try raw.compactMap { match in
            let want = try pick(match.want, from: wanted, what: "want")
            let offer = try pick(match.offer, from: offered, what: "offer")
            guard seen.insert([match.want, match.offer]).inserted else { return nil }
            return KeywordMatch(wanted: want, offered: offer, strength: match.same ? .equivalent : .satisfies)
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
