import Foundation
import StarlingCore

/// One chip under "Starling understood" (Oliver's device test, 2026-10-02).
/// Every chip is applied and tappable: a tap edits that one thing in place,
/// an optional chip can be removed, and a required one (the activity, Find
/// a time's range) can be edited but not removed. Edit still opens the full
/// details.
public struct ComposeChip: Hashable, Sendable, Identifiable {
    public enum Part: Hashable, Sendable {
        /// The skill's own chip. For Down for... it carries the activity
        /// ("Down for boba"), so no other chip repeats it.
        case skill
        case issue(IssueKey)
        case mode
        case audience
        case expiry
    }

    /// How a tap edits the chip.
    public enum Editor: Hashable, Sendable {
        /// Nothing to edit here (another skill's name; the tiles change it).
        case none
        /// Words, comma separated: the activity, a place, a diet.
        case words(IssueKey, String)
        /// One time window, start and end.
        case time(TimeSlot?)
        /// A range of days, optionally evenings only (Find a time).
        case days(DayRange)
        case mode
        case audience
        case expiry
        /// The full details sheet (a budget, a party size, several windows).
        case details
    }

    public let part: Part
    public let text: String
    public let editor: Editor
    public let isRemovable: Bool
    public var id: Part { part }
}

/// Find a time's "when": from one day to another, optionally evenings
/// only (device test 2, issue #95).
public struct DayRange: Hashable, Sendable {
    /// 5 PM to 10 PM, in minutes of the day.
    public static let evenings = (from: 17 * 60, to: 22 * 60)

    public var from: Date
    public var to: Date
    public var eveningsOnly: Bool

    public init(from: Date, to: Date, eveningsOnly: Bool) {
        self.from = from
        self.to = to
        self.eveningsOnly = eveningsOnly
    }
}

extension ComposerModel {
    /// The chips in order: the skill, what the request asks about, then
    /// how, who, and for how long.
    public var chipItems: [ComposeChip] {
        guard let descriptor else { return [] }
        let required = descriptor.intent.requiredIssues
        var items: [ComposeChip] = []
        let carriesActivity = descriptor.id == .downFor
        if let skillChip {
            items.append(ComposeChip(part: .skill, text: skillChip,
                                     editor: carriesActivity ? .words(.activity, words(for: .activity)) : .none, isRemovable: false))
        }
        for issue in chipFormatter.orderedIssues(constraints) where !(carriesActivity && issue == .activity) {
            let rules = constraints.constraints[issue] ?? []
            // Keyword chips in the owner's words as typed (device test, 2026-10-02).
            let text = rules.flatMap { chipFormatter.chips(for: $0.rule, issue: issue, typed: self.text) }.joined(separator: ", ")
            guard !text.isEmpty else { continue }
            items.append(ComposeChip(part: .issue(issue), text: text, editor: editor(for: issue, rules: rules), isRemovable: !required.contains(issue)))
        }
        if descriptor.sendModes.count > 1 {
            items.append(ComposeChip(part: .mode, text: Self.modeLabel(sendMode), editor: .mode, isRemovable: false))
        }
        if let audienceText {
            items.append(ComposeChip(part: .audience, text: audienceText, editor: .audience, isRemovable: true))
        }
        if descriptor.intent.asksForExpiry {
            items.append(ComposeChip(part: .expiry, text: expiryChip, editor: .expiry, isRemovable: false))
        }
        return items
    }

    /// The liked words of an issue, comma separated.
    func words(for issue: IssueKey) -> String {
        (constraints.constraints[issue] ?? []).flatMap { constraint -> [String] in
            if case .prefers(let liked, _) = constraint.rule { return liked.map { ChipFormatter.spelling(of: $0, in: text) ?? $0.value } }
            return []
        }.joined(separator: ", ")
    }

    private func editor(for issue: IssueKey, rules: [Constraint]) -> ComposeChip.Editor {
        if issue == .time, descriptor?.id == .findATime { return .days(dayRange) }
        if rules.allSatisfy({ if case .prefers = $0.rule { true } else { false } }) { return .words(issue, words(for: issue)) }
        if issue == .time, rules.count == 1, case .within(let slots) = rules[0].rule, slots.count == 1 { return .time(slots[0]) }
        return .details
    }

    /// Replaces an issue's words ("movie night, IKEA trip"), keeping what
    /// it avoids. Empty words remove an optional issue; a required one
    /// keeps its words. Returns whether the change applied.
    @discardableResult
    public func setWords(_ text: String, for issue: IssueKey) -> Bool {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if parts.isEmpty {
            guard !(descriptor?.intent.requiredIssues.contains(issue) ?? false) else { return false }
            return remove(.issue(issue))
        }
        guard let liked = try? parts.map({ try Keyword($0) }) else { return false }
        let existing = constraints.constraints[issue] ?? []
        var avoided: [Keyword] = []
        var strength = Constraint.Strength.hard
        for constraint in existing {
            if case .prefers(_, let away) = constraint.rule { avoided += away; strength = constraint.strength }
        }
        guard let rule = try? Constraint(.prefers(liked: liked, avoided: avoided), strength: strength) else { return false }
        return replace(issue, with: [rule])
    }

    /// Replaces the time asked about with one window.
    @discardableResult
    public func setTime(_ slot: TimeSlot) -> Bool {
        let strength = constraints.constraints[.time]?.first?.strength ?? .hard
        guard let rule = try? Constraint(.within([slot]), strength: strength) else { return false }
        return replace(.time, with: [rule])
    }

    /// The days the time chip asks about, for Find a time (device test 2):
    /// from the first day the request allows to the last, and whether only
    /// evenings. A week from today when nothing is set.
    public var dayRange: DayRange {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let rules = constraints.constraints[.time] ?? []
        var from = calendar.startOfDay(for: now())
        var to = calendar.date(byAdding: .day, value: 6, to: from) ?? from
        var evenings = false
        for rule in rules {
            switch rule.rule {
            case .within(let slots):
                if let start = slots.map(\.start).min(), let end = slots.map(\.end).max() {
                    from = calendar.startOfDay(for: start)
                    to = calendar.startOfDay(for: end.addingTimeInterval(-60))
                }
            case .dailyWindow(let start, let end):
                evenings = start == DayRange.evenings.from && end == DayRange.evenings.to
            default:
                break
            }
        }
        return DayRange(from: from, to: to, eveningsOnly: evenings)
    }

    /// Asks about whole days from `range.from` through `range.to`, optionally
    /// evenings only. At most two weeks, the longest window a request can
    /// carry. Returns whether it applied.
    @discardableResult
    public func setDays(_ range: DayRange) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: range.from)
        let lastDay = calendar.startOfDay(for: range.to)
        guard lastDay >= start, let end = calendar.date(byAdding: .day, value: 1, to: lastDay),
              let slot = try? TimeSlot(start: start, end: end) else { return false }
        let strength = constraints.constraints[.time]?.first?.strength ?? .hard
        var rules: [Constraint] = []
        guard let within = try? Constraint(.within([slot]), strength: strength) else { return false }
        rules.append(within)
        if range.eveningsOnly {
            guard let evenings = try? Constraint(.dailyWindow(from: DayRange.evenings.from, to: DayRange.evenings.to), strength: strength) else { return false }
            rules.append(evenings)
        }
        return replace(.time, with: rules)
    }

    /// Removes an optional chip: an issue the skill does not require, or a
    /// narrowed audience (back to all friends). Returns whether it did.
    @discardableResult
    public func remove(_ part: ComposeChip.Part) -> Bool {
        switch part {
        case .issue(let issue):
            guard !(descriptor?.intent.requiredIssues.contains(issue) ?? false), constraints.constraints[issue] != nil else { return false }
            var next = constraints.constraints
            next[issue] = nil
            guard let set = try? ConstraintSet(next) else { return false }
            constraints = set
            return true
        case .audience:
            audience = .allFriends
            picked = []
            excepted = []
            return true
        case .skill, .mode, .expiry:
            return false
        }
    }

    private func replace(_ issue: IssueKey, with rules: [Constraint]) -> Bool {
        var next = constraints.constraints
        next[issue] = rules
        guard let set = try? ConstraintSet(next) else { return false }
        constraints = set
        return true
    }
}
