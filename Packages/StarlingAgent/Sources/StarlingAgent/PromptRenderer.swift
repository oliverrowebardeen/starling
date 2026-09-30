import Foundation
import StarlingCore

/// A rendered decision prompt and the numbered options it offered the model.
package struct DecisionPrompt: Hashable, Sendable {
    package let text: String
    package let timeOptions: [TimeSlot]
    package let activityOptions: [Keyword]
}

/// Turns Core values into short prompts (TN3193: fewer tokens, clearer
/// verbs). Pure and deterministic so tests can pin exactly what the model
/// sees. The only peer data rendered is typed: slots, keywords, amounts.
package enum PromptRenderer {
    package static let maxTimeOptions = 8
    package static let maxActivityOptions = 10

    package static let decideInstructions = """
        You negotiate a plan for your owner with a friend's agent. Choose one move. \
        accept: only if no proposal item is marked BREAKS LIMIT. \
        counter: pick option numbers that fit the owner's limits and stay close to the proposal. \
        reject: no option can fit the owner's limits. \
        Use only listed options. Never exceed the owner's budget.
        """

    package static let interpretInstructions = """
        Turn the owner's message into plan rules. Fill a field only from the owner's own words. \
        Activities are short lowercase things to do or eat, never times, prices, or rules about sharing.
        """

    package static let matchInstructions = """
        Match what the owner wants to what a friend offers. \
        A match means the offer satisfies the want, like "food" and "boba run". \
        Mark same when both mean the same thing.
        """

    package static func decide(_ context: NegotiationContext, timeZone: TimeZone) -> DecisionPrompt {
        let proposal = context.proposal.terms
        var lines = ["Owner limits:"]
        for key in context.constraints.constraints.keys.sorted() {
            for constraint in context.constraints[key] {
                lines.append("- \(key): \(describe(constraint.rule, timeZone: timeZone))\(constraint.strength == .soft ? " (flexible)" : "")")
            }
        }

        lines.append("Proposal (round \(context.proposal.round + 1)):")
        let conflicts = Set(context.constraints.violations(of: proposal, timeZone: timeZone).map(\.issue))
        for key in proposal.values.keys.sorted() {
            let mark = conflicts.contains(key) ? " BREAKS LIMIT" : ""
            lines.append("- \(key): \(describe(proposal.values[key]!, timeZone: timeZone))\(mark)")
        }

        if !context.history.isEmpty {
            let history = context.history.suffix(4).map { "\($0.actor.rawValue) \($0.kind.rawValue)" }.joined(separator: ", ")
            lines.append("Earlier: \(history)")
        }

        let timeOptions = unique(ownerSlots(context.constraints) + slots(in: proposal)).prefix(maxTimeOptions)
        let activityOptions = unique(likedKeywords(context.constraints) + keywords(in: proposal)).prefix(maxActivityOptions)
        if !timeOptions.isEmpty {
            lines.append("Time options: " + timeOptions.enumerated().map { "\($0.offset + 1)) \(format($0.element, timeZone: timeZone))" }.joined(separator: " "))
        }
        if !activityOptions.isEmpty {
            lines.append("Activity options: " + activityOptions.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: " "))
        }

        return DecisionPrompt(text: lines.joined(separator: "\n"), timeOptions: Array(timeOptions), activityOptions: Array(activityOptions))
    }

    package static func interpret(_ utterance: OwnerUtterance, context: InterpretationContext) -> String {
        "Owner: \(utterance.text)"
    }

    package static func match(wanted: [Keyword], offered: [Keyword]) -> String {
        let wants = wanted.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: " ")
        let offers = offered.enumerated().map { "\($0.offset + 1)) \($0.element)" }.joined(separator: " ")
        return "Wants: \(wants)\nOffers: \(offers)"
    }

    // MARK: - Formatting

    package static func describe(_ rule: Constraint.Rule, timeZone: TimeZone) -> String {
        switch rule {
        case .within(let slots): return slots.map { format($0, timeZone: timeZone) }.joined(separator: ", ")
        case .dailyWindow(let from, let to): return "daily \(hhmm(from))-\(hhmm(to))"
        case .prefers(let liked, let avoided):
            var parts: [String] = []
            if !liked.isEmpty { parts.append("likes " + liked.map(\.value).joined(separator: ", ")) }
            if !avoided.isEmpty { parts.append("avoids " + avoided.map(\.value).joined(separator: ", ")) }
            return parts.joined(separator: "; ")
        case .atMost(let amount): return "at most \(money(amount))"
        case .atLeast(let amount): return "at least \(money(amount))"
        case .mustBe(let flag): return flag ? "required" : "not wanted"
        case .countBetween(let min, let max): return "\(min) to \(max)"
        }
    }

    package static func describe(_ value: IssueValue, timeZone: TimeZone) -> String {
        switch value {
        case .slots(let slots): return slots.map { format($0, timeZone: timeZone) }.joined(separator: ", ")
        case .keywords(let keywords): return keywords.map(\.value).joined(separator: ", ")
        case .amount(let amount): return money(amount)
        case .flag(let flag): return flag ? "yes" : "no"
        case .count(let count): return "\(count)"
        }
    }

    package static func format(_ slot: TimeSlot, timeZone: TimeZone) -> String {
        let startDay = weekdayName(slot.start, timeZone: timeZone)
        let endDay = weekdayName(slot.end.addingTimeInterval(-1), timeZone: timeZone)
        let range = "\(clock(slot.start, timeZone: timeZone))-\(clock(slot.end, timeZone: timeZone))"
        return startDay == endDay ? "\(startDay) \(range)" : "\(startDay) \(clock(slot.start, timeZone: timeZone))-\(endDay) \(clock(slot.end, timeZone: timeZone))"
    }

    package static func money(_ amount: MoneyAmount) -> String {
        let whole = amount.minorUnits / 100
        let cents = amount.minorUnits % 100
        let number = cents == 0 ? "\(whole)" : String(format: "%lld.%02lld", whole, cents)
        return amount.currency == "USD" ? "$\(number)" : "\(number) \(amount.currency)"
    }

    private static func clock(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return hhmm((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    private static func weekdayName(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][calendar.component(.weekday, from: date) - 1]
    }

    private static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    // MARK: - Options

    private static func ownerSlots(_ constraints: ConstraintSet) -> [TimeSlot] {
        constraints[.time].flatMap { constraint -> [TimeSlot] in
            if case .within(let slots) = constraint.rule { return slots }
            return []
        }
    }

    private static func likedKeywords(_ constraints: ConstraintSet) -> [Keyword] {
        constraints[.activity].flatMap { constraint -> [Keyword] in
            if case .prefers(let liked, _) = constraint.rule { return liked }
            return []
        }
    }

    private static func slots(in terms: Terms) -> [TimeSlot] {
        if case .slots(let slots) = terms[.time] { return slots }
        return []
    }

    private static func keywords(in terms: Terms) -> [Keyword] {
        if case .keywords(let keywords) = terms[.activity] { return keywords }
        return []
    }

    private static func unique<T: Hashable>(_ items: [T]) -> [T] {
        var seen = Set<T>()
        return items.filter { seen.insert($0).inserted }
    }
}
