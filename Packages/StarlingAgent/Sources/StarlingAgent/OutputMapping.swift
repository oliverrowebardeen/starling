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
                guard prompt.timeOptions.indices.contains(option - 1) else {
                    throw AgentModelError.invalidOutput("time option \(option) not offered")
                }
                values[.time] = .slots([prompt.timeOptions[option - 1]])
                changed = true
            }
            if let option = raw.activityOption {
                guard prompt.activityOptions.indices.contains(option - 1) else {
                    throw AgentModelError.invalidOutput("activity option \(option) not offered")
                }
                values[.activity] = .keywords([prompt.activityOptions[option - 1]])
                changed = true
            }
            if let dollars = raw.budgetDollars {
                guard let amount = try? MoneyAmount(minorUnits: Int64(dollars) * 100) else {
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

        let earliest = raw.earliestHour.map { min(max($0, 0), 23) }
        let latest = raw.latestHour.map { min(max($0, 1), 24) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        if let day = raw.day.flatMap({ Self.dayOffset($0, now: context.now, calendar: calendar) }) {
            let midnight = calendar.startOfDay(for: context.now)
            if let dayStart = calendar.date(byAdding: .day, value: day, to: midnight) {
                let from = dayStart.addingTimeInterval(Double(earliest ?? 0) * 3600)
                let to = dayStart.addingTimeInterval(Double(latest ?? 24) * 3600)
                if to > from, let slot = try? TimeSlot(start: from, end: to) {
                    constraints[.time, default: []].append(try Constraint(.within([slot])))
                }
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

        if let dollars = raw.maxDollars, dollars >= 0, let amount = try? MoneyAmount(minorUnits: Int64(dollars) * 100) {
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
            guard wanted.indices.contains(match.want - 1), offered.indices.contains(match.offer - 1) else {
                throw AgentModelError.invalidOutput("match \(match.want)->\(match.offer) out of range")
            }
            guard seen.insert([match.want, match.offer]).inserted else { return nil }
            return KeywordMatch(wanted: wanted[match.want - 1], offered: offered[match.offer - 1], strength: match.same ? .equivalent : .satisfies)
        }
    }

    private static func keywords(_ strings: [String]) -> [Keyword] {
        var seen = Set<Keyword>()
        return strings.compactMap { try? Keyword($0) }.filter { seen.insert($0).inserted }.prefix(ProtocolLimits.maxKeywordsPerValue).map { $0 }
    }
}
