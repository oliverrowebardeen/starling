import FoundationModels

// @Generable schemas. Kept small: every property, name, and guide costs
// context tokens (TN3193). The model answers with option numbers instead of
// free text wherever it can, so output is short and checkable.

@Generable
enum MoveKind {
    case accept, counter, reject
}

@Generable
struct MoveOutput {
    // Generated first on purpose: the model writes properties in order, and
    // naming the conflicts before choosing a move stops it from committing
    // to "accept" first (Phase 0 bench, docs/research/model-budget.md).
    @Guide(description: "Proposal items marked BREAKS LIMIT", .maximumCount(4))
    var brokenItems: [String]
    var move: MoveKind
    @Guide(description: "Counter only: time option number")
    var timeOption: Int?
    @Guide(description: "Counter only: activity option number")
    var activityOption: Int?
    @Guide(description: "Counter only: budget in whole dollars")
    var budgetDollars: Int?

    var raw: RawMove {
        let kind: RawMove.Kind = switch move {
        case .accept: .accept
        case .counter: .counter
        case .reject: .reject
        }
        return RawMove(kind: kind, timeOption: timeOption, activityOption: activityOption, budgetDollars: budgetDollars)
    }
}

@Generable
enum DayName {
    case today, tomorrow, monday, tuesday, wednesday, thursday, friday, saturday, sunday
}

@Generable
struct RulesOutput {
    @Guide(description: "Day the owner named, if any")
    var day: DayName?
    @Guide(description: "Earliest hour the owner named, 0-23")
    var earliestHour: Int?
    @Guide(description: "Latest hour the owner named, 1-24")
    var latestHour: Int?
    @Guide(description: "Activities the owner asked for, empty if none", .maximumCount(5))
    var wants: [String]
    @Guide(description: "Activities the owner ruled out, empty if none", .maximumCount(5))
    var avoids: [String]
    @Guide(description: "Price limit in whole dollars, only if the owner named one")
    var maxDollars: Int?
    @Guide(description: "True only if the owner said not to share their location")
    var hideLocation: Bool
    @Guide(description: "True only if the owner said not to share their schedule")
    var hideSchedule: Bool
    @Guide(description: "True only if the owner said not to share their budget")
    var hideBudget: Bool

    var raw: RawRules {
        var hidden: [RawRules.Shareable] = []
        if hideLocation { hidden.append(.location) }
        if hideSchedule { hidden.append(.schedule) }
        if hideBudget { hidden.append(.budget) }
        let dayValue: RawRules.Day? = switch day {
        case .today: .relative(0)
        case .tomorrow: .relative(1)
        case .monday: .weekday(2)
        case .tuesday: .weekday(3)
        case .wednesday: .weekday(4)
        case .thursday: .weekday(5)
        case .friday: .weekday(6)
        case .saturday: .weekday(7)
        case .sunday: .weekday(1)
        case nil: nil
        }
        return RawRules(
            day: dayValue, earliestHour: earliestHour, latestHour: latestHour,
            wants: wants, avoids: avoids, maxDollars: maxDollars, neverShare: hidden
        )
    }
}

@Generable
struct MatchPair {
    @Guide(description: "Want number")
    var want: Int
    @Guide(description: "Offer number")
    var offer: Int
    @Guide(description: "True if they mean the same thing")
    var same: Bool
}

@Generable
struct MatchOutput {
    @Guide(.maximumCount(16))
    var matches: [MatchPair]

    var raw: [RawMatch] { matches.map { RawMatch(want: $0.want, offer: $0.offer, same: $0.same) } }
}
