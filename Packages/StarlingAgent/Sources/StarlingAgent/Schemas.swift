import FoundationModels

// @Generable schemas. Kept small: every property, name, and guide costs
// context tokens (TN3193). The model answers with option numbers instead of
// free text wherever it can, so output is short and checkable.

@Generable
enum DayName {
    case none, today, tonight, tomorrow, monday, tuesday, wednesday, thursday, friday, saturday, sunday
}

@Generable
enum PartOfDay {
    case none, morning, lunch, afternoon, evening
}

@Generable
struct RulesOutput {
    @Guide(description: "Day the owner named")
    var day: DayName
    @Guide(description: "Earliest hour the owner named, 0-23, or 0 if none")
    var earliestHour: Int
    @Guide(description: "Latest hour the owner named, 1-24, or 24 if none")
    var latestHour: Int
    @Guide(description: "Part of the day the owner named, if no hours")
    var partOfDay: PartOfDay
    @Guide(description: "Most the owner will spend in whole dollars, or 0 if none")
    var maxDollars: Int
    @Guide(description: "Things to do or eat that the owner asked for", .maximumCount(5))
    var wants: [String]
    @Guide(description: "Things to do or eat that the owner ruled out", .maximumCount(5))
    var avoids: [String]
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
        case .none: nil
        case .today, .tonight: .relative(0)
        case .tomorrow: .relative(1)
        case .monday: .weekday(2)
        case .tuesday: .weekday(3)
        case .wednesday: .weekday(4)
        case .thursday: .weekday(5)
        case .friday: .weekday(6)
        case .saturday: .weekday(7)
        case .sunday: .weekday(1)
        }
        let part: RawRules.PartOfDay? = switch (day, partOfDay) {
        case (.tonight, _), (_, .evening): .evening
        case (_, .morning): .morning
        case (_, .lunch): .lunch
        case (_, .afternoon): .afternoon
        case (_, .none): nil
        }
        // 0, 24, and 0 are the schema's way of saying "not stated".
        return RawRules(
            day: dayValue, partOfDay: part,
            earliestHour: earliestHour == 0 ? nil : earliestHour,
            latestHour: latestHour == 24 ? nil : latestHour,
            wants: wants, avoids: avoids, maxDollars: maxDollars == 0 ? nil : maxDollars, neverShare: hidden
        )
    }
}
