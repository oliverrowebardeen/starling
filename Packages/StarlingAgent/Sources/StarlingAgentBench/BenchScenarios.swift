import Foundation
import StarlingCore

/// A two-sided negotiation: A opens with `opening`, then the sides alternate.
public struct DecideScenario: Sendable {
    public let name: String
    public let summary: String
    public let a: ConstraintSet
    public let b: ConstraintSet
    public let opening: Terms
}

public struct MatchCase: Sendable {
    public let name: String
    public let wanted: [Keyword]
    public let offered: [Keyword]
}

/// Realistic Phase 0 workloads, sized from the brief's v1 features.
public enum BenchScenarios {
    public static let maxRounds = 6

    public static let utterances = [
        "free tonight, want food, under $15, not far",
        "no plans before 10, never share where I am",
        "saturday afternoon works, anything but sushi, budget like 20 bucks",
        "down for boba or tacos after 8 tonight, don't tell people my schedule",
    ]

    public static func decide(now: Date, timeZone: TimeZone) throws -> [DecideScenario] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        func slot(day: Int = 0, _ from: Double, _ to: Double) throws -> TimeSlot {
            let base = today.addingTimeInterval(Double(day) * 86_400)
            return try TimeSlot(start: base.addingTimeInterval(from * 3600), end: base.addingTimeInterval(to * 3600))
        }
        func words(_ list: String) throws -> [Keyword] {
            try list.split(separator: ",").map { try Keyword(String($0)) }
        }
        func dollars(_ value: Int64) throws -> MoneyAmount { try MoneyAmount(minorUnits: value * 100) }

        let down = DecideScenario(
            name: "down-2p",
            summary: "Two friends, three issues: time, activity, budget",
            a: try ConstraintSet([
                .time: [try Constraint(.within([try slot(18, 23)]))],
                .activity: [try Constraint(.prefers(liked: try words("food,boba"), avoided: []), strength: .soft)],
                .budget: [try Constraint(.atMost(try dollars(15)))],
            ]),
            b: try ConstraintSet([
                .time: [try Constraint(.within([try slot(20, 24)]))],
                .activity: [try Constraint(.prefers(liked: try words("boba,tacos"), avoided: try words("sushi")), strength: .soft)],
                .budget: [try Constraint(.atMost(try dollars(12)))],
            ]),
            opening: try Terms([
                .time: .slots([try slot(19, 21)]),
                .activity: .keywords(try words("dinner")),
                .budget: .amount(try dollars(15)),
            ])
        )

        let group = DecideScenario(
            name: "group-4p",
            summary: "One agent weighing a proposal against four friends' pooled options",
            a: try ConstraintSet([
                .time: [try Constraint(.within([try slot(17, 19), try slot(19, 21), try slot(21, 23)]))],
                .activity: [try Constraint(.prefers(liked: try words("pizza,ramen,boba,bowling"), avoided: []), strength: .soft)],
                .budget: [try Constraint(.atMost(try dollars(25)))],
            ]),
            b: try ConstraintSet([
                .time: [try Constraint(.within([try slot(18, 20), try slot(19, 22), try slot(20, 23), try slot(21, 24)]))],
                .activity: [try Constraint(.prefers(
                    liked: try words("ramen,tacos,boba,karaoke,bowling,thai food"),
                    avoided: try words("sushi,bars,seafood")
                ), strength: .soft)],
                .budget: [try Constraint(.atMost(try dollars(20)))],
                .partySize: [try Constraint(.countBetween(min: 3, max: 6))],
            ]),
            opening: try Terms([
                .time: .slots([try slot(19, 21), try slot(20, 22), try slot(21, 23)]),
                .activity: .keywords(try words("pizza,ramen,bowling,karaoke")),
                .budget: .amount(try dollars(25)),
                .partySize: .count(4),
            ])
        )

        let parent = DecideScenario(
            name: "parent-student",
            summary: "Calendar-driven parent and no-calendar student find a weekend time",
            a: try ConstraintSet([
                .time: [try Constraint(.within([try slot(day: 1, 9, 12), try slot(day: 1, 13, 17), try slot(day: 2, 10, 14)]))],
            ]),
            b: try ConstraintSet([
                .time: [
                    try Constraint(.within([try slot(day: 1, 12, 18), try slot(day: 2, 11, 16), try slot(day: 2, 19, 22)])),
                    try Constraint(.dailyWindow(from: 600, to: 1440)),
                ],
            ]),
            opening: try Terms([.time: .slots([try slot(day: 1, 9, 11)])])
        )

        return [down, group, parent]
    }

    public static func matches() throws -> [MatchCase] {
        func words(_ list: String) throws -> [Keyword] {
            try list.split(separator: ",").map { try Keyword(String($0)) }
        }
        return [
            MatchCase(name: "food-vs-boba", wanted: try words("food"), offered: try words("boba run,movie")),
            MatchCase(name: "group-menu", wanted: try words("noodles,something sweet,cheap eats"), offered: try words("ramen,boba,tacos,karaoke,pho,ice cream")),
            MatchCase(name: "max-lists", wanted: try words("food,outdoors,music,games,coffee,study"), offered: try words("boba run,hike,concert,board games,cafe,library,tacos,beach,karaoke,arcade")),
        ]
    }
}
