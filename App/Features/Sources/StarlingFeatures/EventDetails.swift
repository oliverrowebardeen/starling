import Foundation
import StarlingCore

/// The Edit sheet's per-event details (device test 2, issue #95): what,
/// when, where, group size, and the most to spend. Standing preferences
/// (daily hours, only at certain times, likes, avoids) live in You › Your
/// rules, not here. Who, how friends are asked, and how long they can
/// answer are the composer's own settings and are edited there directly.
public struct EventDetails: Hashable, Sendable {
    public enum Field: Hashable, Sendable, CaseIterable {
        case what, when, place, groupSize, spendAtMost
    }

    /// The fields this skill asks about, in the order the sheet shows them.
    public var fields: [Field]
    public var what: String
    /// A window with a start and an end, for skills other than Find a time;
    /// nil when no time is set.
    public var window: TimeSlot?
    /// Find a time's range of days.
    public var days: DayRange?
    public var place: String
    /// The group size, smallest to largest.
    public var groupSize: ClosedRange<Int>?
    /// The most to spend, in whole units of `currency`; nil for no limit.
    public var spendAtMost: Decimal?
    public var currency: String
}

extension ComposerModel {
    /// The details as the chips stand now.
    public var eventDetails: EventDetails {
        let slots = Set(descriptor?.intent.slots.map(\.issue) ?? [])
        var fields: [EventDetails.Field] = []
        if slots.contains(.activity) { fields.append(.what) }
        if slots.contains(.time) { fields.append(.when) }
        if slots.contains(.place) { fields.append(.place) }
        if slots.contains(.partySize) { fields.append(.groupSize) }
        if slots.contains(.budget) { fields.append(.spendAtMost) }
        let isFindATime = descriptor?.id == .findATime
        var window: TimeSlot?
        var groupSize: ClosedRange<Int>?
        var spend: Decimal?
        var currency = Locale.current.currency?.identifier ?? "USD"
        for constraint in constraints.constraints[.time] ?? [] {
            if case .within(let slots) = constraint.rule, window == nil { window = slots.sorted().first }
        }
        for constraint in constraints.constraints[.partySize] ?? [] {
            if case .countBetween(let low, let high) = constraint.rule, low <= high { groupSize = low...high }
        }
        for constraint in constraints.constraints[.budget] ?? [] {
            if case .atMost(let amount) = constraint.rule {
                spend = Decimal(amount.minorUnits) / 100
                currency = amount.currency
            }
        }
        return EventDetails(
            fields: fields, what: words(for: .activity), window: isFindATime ? nil : window,
            days: isFindATime ? dayRange : nil, place: words(for: .place), groupSize: groupSize,
            spendAtMost: spend, currency: currency
        )
    }

    /// Applies the sheet. Checks everything first and changes nothing when
    /// something can't be used; returns why, in plain words, or nil.
    @discardableResult
    public func apply(_ details: EventDetails) -> String? {
        let required = descriptor?.intent.requiredIssues ?? []
        let fields = Set(details.fields)
        let previous = constraints
        if fields.contains(.what) {
            let words = details.what.trimmingCharacters(in: .whitespacesAndNewlines)
            if words.isEmpty, required.contains(.activity) { return "Add what you want to do." }
        }
        if fields.contains(.when), let days = details.days, days.to < days.from { return "The last day comes before the first." }
        if let spend = details.spendAtMost, spend < 0 { return "The most to spend can't be below zero." }
        if let size = details.groupSize, size.lowerBound < 2 { return "A group is at least 2 people." }

        var ok = true
        if fields.contains(.what) { ok = setWords(details.what, for: .activity) && ok }
        if fields.contains(.place) {
            let place = details.place.trimmingCharacters(in: .whitespacesAndNewlines)
            ok = (place.isEmpty ? (constraints.constraints[.place] == nil || remove(.issue(.place))) : setWords(place, for: .place)) && ok
        }
        if fields.contains(.when) {
            if let days = details.days {
                ok = setDays(days) && ok
            } else if let window = details.window {
                ok = setTime(window) && ok
            } else if constraints.constraints[.time] != nil {
                ok = remove(.issue(.time)) && ok
            }
        }
        if fields.contains(.groupSize) {
            let size = details.groupSize.flatMap { range in try? Constraint(Constraint.Rule.countBetween(min: range.lowerBound, max: range.upperBound)) }
            ok = setRule(size, for: .partySize) && ok
        }
        if fields.contains(.spendAtMost) {
            let amount = details.spendAtMost.flatMap { spend -> MoneyAmount? in
                let cents = NSDecimalNumber(decimal: spend * 100).int64Value
                return try? MoneyAmount(minorUnits: cents, currency: details.currency)
            }
            if details.spendAtMost != nil, amount == nil { ok = false } else {
                ok = setRule(amount.flatMap { value in try? Constraint(Constraint.Rule.atMost(value)) }, for: .budget) && ok
            }
        }
        guard ok else {
            constraints = previous
            return "Starling can't use one of these details. Try plain words or numbers."
        }
        return nil
    }

    /// Sets one rule for an optional issue, or removes it when nil.
    private func setRule(_ rule: Constraint?, for issue: IssueKey) -> Bool {
        guard let rule else { return constraints.constraints[issue] == nil || remove(.issue(issue)) }
        var next = constraints.constraints
        next[issue] = [rule]
        guard let set = try? ConstraintSet(next) else { return false }
        constraints = set
        return true
    }
}
