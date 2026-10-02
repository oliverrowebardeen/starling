import Foundation
import StarlingAvailability
import StarlingCore

// What Find a time puts on the wire and how it reads what comes back. Every
// value is typed and bounded (ARCHITECTURE rule 7); everything a peer sends
// is checked here before the service acts on it.

/// The times an owner's request covers: the range and daily window from the
/// chips, as candidate slots in the owner's time zone.
enum SearchRange {
    /// Every candidate the owner's request allows: inside every hard
    /// `within` window (several are intersected, not joined: each is a
    /// limit the owner set), inside the daily window, within the horizon,
    /// and breaking none of the owner's hard limits (ARCHITECTURE rule 6).
    static func candidates(rules: OwnerRules, now: Date, timeZone: TimeZone, configuration: FindATimeConfiguration) throws -> [TimeSlot] {
        let timeRules = rules.constraints[.time]
        // Without hours of the owner's own, a meal's usual hours ("dinner"
        // is the evening), else the skill's default (issue #95).
        let defaultHours = FindATimeDefaults.dailyWindow(for: activity(in: rules)) ?? (configuration.dailyFrom, configuration.dailyTo)
        var dailyFrom = defaultHours.0
        var dailyTo = defaultHours.1
        var ownerDaily = false
        for constraint in timeRules {
            if case .dailyWindow(let from, let to) = constraint.rule {
                // Several daily windows narrow each other, starting from the
                // owner's first rather than the default.
                if !ownerDaily { (dailyFrom, dailyTo, ownerDaily) = (from, to, true) }
                dailyFrom = max(dailyFrom, from)
                dailyTo = min(dailyTo, to)
            }
        }
        let windows: (Constraint.Strength) -> [[TimeSlot]] = { strength in
            timeRules.compactMap { constraint in
                if case .within(let slots) = constraint.rule, constraint.strength == strength { slots } else { nil }
            }
        }
        // Hard windows bound the search; soft ones are used only when the
        // owner gave no hard one.
        let limits = windows(.hard).isEmpty ? windows(.soft) : windows(.hard)
        let horizon = now.addingTimeInterval(TimeInterval(configuration.maxRangeDays) * 86_400)
        var ranges: [TimeSlot]
        if let first = limits.first {
            ranges = limits.dropFirst().reduce(first) { intersect($0, $1) }
        } else if let range = try? TimeSlot(start: now, end: now.addingTimeInterval(TimeInterval(configuration.defaultRangeDays) * 86_400)) {
            ranges = [range]
        } else {
            ranges = []
        }
        ranges = ranges.compactMap { range -> TimeSlot? in
            let start = max(range.start, now)
            let end = min(range.end, horizon)
            return end > start ? try? TimeSlot(start: start, end: end) : nil
        }
        guard let grid = try? CandidateGrid(durationMinutes: configuration.slotMinutes, dailyFrom: dailyFrom, dailyTo: dailyTo) else {
            throw FindATimeError.noTimesInRange
        }
        let slots = HardLimits.allowed(grid.slots(in: ranges, notBefore: now, timeZone: timeZone), by: rules.constraints, timeZone: timeZone)
        guard !slots.isEmpty else { throw FindATimeError.noTimesInRange }
        return slots
    }

    /// The parts of time both lists cover.
    static func intersect(_ a: [TimeSlot], _ b: [TimeSlot]) -> [TimeSlot] {
        Array(Set(a.flatMap { x in b.compactMap { x.overlap(with: $0) } })).sorted()
    }

    /// The first activity the owner named, for the plan ("stats").
    static func activity(in rules: OwnerRules) -> Keyword? {
        for constraint in rules.constraints[.activity] {
            if case .prefers(let liked, _) = constraint.rule, let first = liked.first { return first }
        }
        return nil
    }
}

/// The owner's hard limits, checked in code before anything is offered or
/// accepted (ARCHITECTURE rule 6), with the one Core implementation.
enum HardLimits {
    static func allows(_ terms: Terms, by constraints: ConstraintSet, timeZone: TimeZone) -> Bool {
        constraints.violations(of: terms, timeZone: timeZone).isEmpty
    }

    static func allowed(_ slots: [TimeSlot], by constraints: ConstraintSet, timeZone: TimeZone) -> [TimeSlot] {
        slots.filter { slot in
            guard let terms = try? Terms([.time: .slots([slot])]) else { return false }
            return allows(terms, by: constraints, timeZone: timeZone)
        }
    }
}

/// A proposal's terms, read back into typed parts.
struct OfferTerms: Hashable, Sendable {
    let slot: TimeSlot
    let activity: Keyword?
    /// The roster, for a plan of three or more.
    let roster: [PeerID]?

    static let allowedIssues: Set<IssueKey> = [.time, .activity, .people]

    /// The terms the starter sends: one time, the activity if any, and the
    /// roster only when there are three or more people (a pair needs none,
    /// and leaving it out keeps the people topic off a two-person request).
    static func terms(slot: TimeSlot, activity: Keyword?, roster: [PeerID]) throws -> Terms {
        var values: [IssueKey: IssueValue] = [.time: .slots([slot])]
        if let activity { values[.activity] = .keywords([activity]) }
        if roster.count >= 3 { values[.people] = .peers(roster) }
        return try Terms(values)
    }

    /// Parses a peer's proposal. Nil for anything but one time, at most one
    /// activity, and a roster that names both us and the sender.
    init?(_ terms: Terms, asker: PeerID, local: PeerID) {
        guard Set(terms.values.keys).isSubset(of: Self.allowedIssues),
              case .slots(let slots)? = terms[.time], slots.count == 1
        else { return nil }
        slot = slots[0]
        switch terms[.activity] {
        case nil: activity = nil
        case .keywords(let keywords)? where keywords.count == 1: activity = keywords[0]
        default: return nil
        }
        switch terms[.people] {
        case nil: roster = nil
        case .peers(let peers)? where peers.count >= 3 && peers.contains(asker) && peers.contains(local): roster = peers.sorted()
        default: return nil
        }
    }

    func plan(origin: ConversationID, asker: PeerID, local: PeerID) throws -> Plan {
        try Plan(origin: origin, attendees: Attendees(roster ?? [asker, local].sorted()), activity: activity, time: slot)
    }
}

/// Checks a friend's query before anything else happens: no interaction,
/// card, or question exists for a query that fails here.
enum QueryCheck {
    static func candidates(of query: Query, now: Date, configuration: FindATimeConfiguration) -> [TimeSlot]? {
        guard query.issue == .time, case .slots(let slots) = query.candidates else { return nil }
        let unique = Array(Set(slots)).sorted()
        guard (1...configuration.maxCandidates).contains(unique.count), unique.count == slots.count else { return nil }
        let nowMinute = Int64((now.timeIntervalSince1970 / 60).rounded(.down))
        // A day of slack past the owner-side range, for clock skew and a
        // request sent late in the day.
        let horizon = nowMinute + Int64(configuration.maxRangeDays + 1) * 1440
        let fits = unique.allSatisfy {
            $0.durationMinutes >= 5 && $0.durationMinutes <= Int64(configuration.maxCandidateMinutes)
                && $0.endMinute > nowMinute && $0.startMinute < horizon
        }
        return fits ? unique : nil
    }
}
