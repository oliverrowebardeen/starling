import Foundation
import StarlingCore

/// What code, not the model, decides about one Down intent: which plans are
/// allowed, how to answer a peer's query, and how to build or repair an offer.
///
/// Every plan that leaves the phone passes `permits` first (ARCHITECTURE
/// rule 6). A Down plan has exactly one time slot, and optionally activity
/// keywords and a budget cap. Nothing else.
struct DownProfile: Sendable {
    /// Where an acceptance carries its sender's level (ADR 0120). Only
    /// `accept` bodies include it, so a level crosses the wire only once the
    /// other side has offered or accepted the same plan.
    static let levelKey = IssueKey.downLevel
    static let planIssues: Set<IssueKey> = [.time, .activity, .budget]

    let level: DownLevel
    let constraints: ConstraintSet
    let tokens: DownTokenSet
    let timeZone: TimeZone
    /// Soft preferences, in the owner's order, never including an avoided one.
    let liked: [Keyword]
    let avoided: Set<Keyword>
    /// The lowest `atMost` on the budget.
    let budgetCap: MoneyAmount?
    /// The intent's free slots as a hard `within` limit, so a plan must also
    /// fall inside the time this intent covers (not in the past, not after it expires).
    private let availability: ConstraintSet

    init(intent: DownIntent, now: Date, timeZone: TimeZone) {
        level = intent.level
        constraints = intent.rules.constraints
        self.timeZone = timeZone
        tokens = DownTokenSet(constraints: constraints, now: now, expiresAt: intent.expiresAt.date, timeZone: timeZone)

        var liked: [Keyword] = []
        var avoided = Set<Keyword>()
        var cap: MoneyAmount?
        for constraint in constraints[.activity] {
            if case .prefers(let like, let avoid) = constraint.rule {
                liked += like
                avoided.formUnion(avoid)
            }
        }
        for constraint in constraints[.budget] {
            if case .atMost(let limit) = constraint.rule, cap == nil || (cap!.currency == limit.currency && limit.minorUnits < cap!.minorUnits) {
                cap = limit
            }
        }
        var seen = Set<Keyword>()
        self.liked = liked.filter { !avoided.contains($0) && seen.insert($0).inserted }
        self.avoided = avoided
        budgetCap = cap

        let windows = Self.merge(tokens.slots)
        availability = (try? ConstraintSet([.time: [try Constraint(.within(windows))]])) ?? .empty
    }

    /// What the PSI set is built from, for the policy (padding is not an
    /// input: it is random and discloses nothing).
    var psiInputs: [IssueKey: IssueValue] { [.time: .slots(tokens.slots)] }

    // MARK: - The gate

    /// True when `plan` has the Down shape and breaks none of the owner's
    /// hard limits. The one check every outbound plan passes.
    func permits(_ plan: Terms) -> Bool {
        isWellFormed(plan) && violations(of: plan).isEmpty
    }

    func violations(of plan: Terms) -> [LimitViolation] {
        constraints.violations(of: plan, timeZone: timeZone) + availability.violations(of: plan, timeZone: timeZone)
    }

    func isWellFormed(_ plan: Terms) -> Bool {
        guard Set(plan.values.keys).isSubset(of: Self.planIssues),
              case .slots(let slots)? = plan[.time], slots.count == 1
        else { return false }
        switch plan[.activity] {
        case nil: break
        case .keywords(let keywords)? where !keywords.isEmpty: break
        default: return false
        }
        switch plan[.budget] {
        // A different currency from the cap is a violation (currencyMismatch).
        case nil, .amount?: break
        default: return false
        }
        return true
    }

    // MARK: - Answering a peer's query

    /// Whether answering an activity query needs `AgentModel.match`. Without
    /// liked activities, any candidate that is not avoided will do.
    var needsModelToMatch: Bool { !liked.isEmpty }

    /// The candidates this owner accepts, in the peer's order. `matches` is
    /// the model's opinion; code keeps only pairs of a liked keyword and a
    /// real candidate, adds exact matches the model missed, and drops
    /// anything avoided.
    func acceptableActivities(candidates: [Keyword], matches: [KeywordMatch]) -> [Keyword] {
        let usable = candidates.filter { !avoided.contains($0) }
        guard needsModelToMatch else { return usable }
        let likedSet = Set(liked)
        var accepted = Set(usable.filter(likedSet.contains))
        for match in matches where likedSet.contains(match.wanted) {
            accepted.insert(match.offered)
        }
        return usable.filter(accepted.contains)
    }

    /// The acceptable part of "up to `candidate`": up to the lower of the two
    /// caps. Nil (decline) when the currencies differ.
    func budgetAnswer(for candidate: MoneyAmount) -> MoneyAmount? {
        guard let cap = budgetCap else { return candidate }
        guard cap.currency == candidate.currency else { return nil }
        return cap.minorUnits < candidate.minorUnits ? cap : candidate
    }

    // MARK: - Offers

    /// The first plan to propose after PSI found `overlap`.
    ///
    /// - Parameters:
    ///   - activities: The peer's acceptable subset of our liked activities,
    ///     or nil if we did not ask. Empty means no shared activity: no plan.
    ///   - budget: The peer's answer to our budget query, if any.
    func openingPlan(overlap: [TimeSlot], activities: [Keyword]?, budget: MoneyAmount?, maxMinutes: Int64) -> Terms? {
        var values: [IssueKey: IssueValue] = [:]
        if let activities {
            let shared = Set(activities)
            guard let pick = liked.first(where: shared.contains) else { return nil }
            values[.activity] = .keywords([pick])
        }
        if let budget {
            values[.budget] = .amount(budgetAnswer(for: budget) ?? budget)
        }
        for block in Self.merge(overlap) {
            let capped = min(block.endMinute, block.startMinute + maxMinutes)
            if let plan = fitTime(start: block.startMinute, end: capped, values: values) { return plan }
        }
        return nil
    }

    enum Assessment: Hashable, Sendable {
        /// The offer is fine as it is. `alternatives` are compliant counters
        /// that would serve a soft preference better; the model may pick one.
        case acceptable(alternatives: [Terms])
        /// The offer breaks a limit, and this compliant counter fixes it.
        case repair(Terms)
        case reject(Rejection.Reason)
    }

    /// Judges a peer's offer in code. `overlap` is the PSI result when known.
    func assess(_ offer: Terms, overlap: [TimeSlot]?, canCounter: Bool) -> Assessment {
        guard isWellFormed(offer) else { return .reject(.unsupported) }
        if violations(of: offer).isEmpty {
            guard canCounter, offer[.activity] == nil, let favorite = liked.first else { return .acceptable(alternatives: []) }
            var values = offer.values
            values[.activity] = .keywords([favorite])
            guard let alternative = try? Terms(values), permits(alternative) else { return .acceptable(alternatives: []) }
            return .acceptable(alternatives: [alternative])
        }
        guard canCounter else { return .reject(.tooManyRounds) }
        return repair(offer, overlap: overlap).map(Assessment.repair) ?? .reject(.noOverlap)
    }

    private func repair(_ offer: Terms, overlap: [TimeSlot]?) -> Terms? {
        var values = offer.values
        if case .amount(let amount)? = values[.budget], let cap = budgetCap,
           amount.currency != cap.currency || amount.minorUnits > cap.minorUnits {
            values[.budget] = .amount(cap)
        }
        if case .keywords(let keywords)? = values[.activity] {
            let kept = keywords.filter { !avoided.contains($0) }
            guard !kept.isEmpty else { return nil }
            values[.activity] = .keywords(kept)
        }
        guard case .slots(let slots)? = values[.time], let slot = slots.first else { return nil }
        // A shorter plan with the same start is inside anything the peer
        // already allowed, so try that first.
        if let plan = fitTime(start: slot.startMinute, end: slot.endMinute, values: values) { return plan }
        for block in Self.merge(overlap ?? []) {
            if let plan = fitTime(start: block.startMinute, end: min(block.endMinute, block.startMinute + slot.durationMinutes), values: values) {
                return plan
            }
        }
        return nil
    }

    /// The longest `[start, end')` with `end' <= end`, shortened a slot at a
    /// time, that makes a permitted plan with `values`.
    private func fitTime(start: Int64, end: Int64, values: [IssueKey: IssueValue]) -> Terms? {
        var end = end
        while end > start {
            var candidate = values
            if let slot = try? TimeSlot(startMinute: start, endMinute: end) {
                candidate[.time] = .slots([slot])
                if let plan = try? Terms(candidate), permits(plan) { return plan }
            }
            end -= min(DownTokenSet.slotMinutes, end - start)
        }
        return nil
    }

    // MARK: - Level

    /// `plan` plus this owner's level, for an `accept` body.
    func accepting(_ plan: Terms) -> Terms {
        var values = plan.values
        values[Self.levelKey] = .keywords([Self.keyword(for: level)])
        // Force-try is safe: a plan has at most three issues.
        return try! Terms(values)
    }

    /// Splits an acceptance into the plan and the sender's level. Nil when
    /// the level is missing or malformed.
    static func split(_ accepted: Terms) -> (plan: Terms, level: DownLevel)? {
        guard case .keywords(let words)? = accepted[levelKey], words.count == 1,
              let level = DownLevel(rawValue: words[0].value)
        else { return nil }
        var values = accepted.values
        values[levelKey] = nil
        guard let plan = try? Terms(values) else { return nil }
        return (plan, level)
    }

    private static func keyword(for level: DownLevel) -> Keyword {
        // Force-try is safe: "down" and "maybe" are valid keywords.
        try! Keyword(level.rawValue)
    }

    // MARK: - Helpers

    /// Sorts slots and joins touching or overlapping ones.
    static func merge(_ slots: [TimeSlot]) -> [TimeSlot] {
        var merged: [TimeSlot] = []
        for slot in slots.sorted() {
            if let last = merged.last, slot.startMinute <= last.endMinute {
                if slot.endMinute > last.endMinute, let joined = try? TimeSlot(startMinute: last.startMinute, endMinute: slot.endMinute) {
                    merged[merged.count - 1] = joined
                }
            } else {
                merged.append(slot)
            }
        }
        return merged
    }
}
