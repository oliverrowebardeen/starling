import Foundation
import StarlingCore

/// Owner utterances labeled with the rules they should produce.
///
/// Written for the failures the Phase 0 bench found (docs/research/model-budget.md,
/// finding 5): sentences about sharing that set every never-share flag,
/// invented activities, and dropped budgets. Several items are negative
/// controls: sharing mentioned but allowed, no activity named, "no budget
/// limit". Hour ranges allow for vague words ("tonight", "afternoon").
///
/// "Now" is fixed so day offsets are reproducible: Tuesday 2026-09-29 12:00 UTC.
public enum InterpretationSet {
    public static let now = Date(timeIntervalSince1970: 1_790_683_200)
    public static let timeZone = TimeZone(identifier: "UTC")!

    /// Evening start and end, for "tonight" and "evening" with no hours.
    static let evening = 17...20
    static let lateEnd = 22...24

    public static let labels: [InterpretationLabel] = [
        // The four Phase 0 bench utterances.
        .init("free tonight, want food, under $15, not far", day: .today, from: evening, to: lateEnd, wants: ["food"], budget: 15),
        .init("no plans before 10, never share where I am", from: 10...10, neverShare: [.place]),
        .init("saturday afternoon works, anything but sushi, budget like 20 bucks", day: .saturday, from: 12...13, to: 17...18, avoids: ["sushi"], budget: 20),
        .init("down for boba or tacos after 8 tonight, don't tell people my schedule", day: .today, from: 20...20, to: lateEnd, wants: ["boba", "tacos"], neverShare: [.time]),

        // Times and days.
        .init("tomorrow after 6pm, dinner, max $25", day: .tomorrow, from: 18...18, to: lateEnd, wants: ["dinner"], budget: 25),
        .init("can't do anything before noon on sunday, want to get brunch", day: .sunday, from: 12...12, to: lateEnd, wants: ["brunch"]),
        .init("friday between 7 and 10pm, bowling or karaoke", day: .friday, from: 19...19, to: 22...22, wants: ["bowling", "karaoke"]),
        .init("I'm free all day thursday", day: .thursday, from: 0...9, to: 20...24),
        .init("lunch today, nothing over $12", day: .today, from: 11...12, to: 13...14, wants: ["lunch"], budget: 12),
        .init("coffee sometime tomorrow morning", day: .tomorrow, from: 6...9, to: 11...12, wants: ["coffee"]),
        .init("free wednesday evening, want to study at the library", day: .wednesday, from: evening, to: 21...24, wants: ["study|library"]),
        .init("free after class at 3 today, want boba", day: .today, from: 15...15, to: lateEnd, wants: ["boba"]),
        .init("no later than 9pm tonight, video games", day: .today, from: 0...18, to: 21...21, wants: ["video games|games|gaming"]),
        .init("monday after 7, ramen, not spending more than twenty", day: .monday, from: 19...19, to: lateEnd, wants: ["ramen"], budget: 20),
        .init("free until 5 today", day: .today, from: 0...12, to: 17...17),
        .init("any time after 11am works, no budget limit, want to play basketball", from: 11...11, wants: ["basketball"]),
        .init("not before noon and not after 10pm, dessert or coffee", from: 12...12, to: 22...22, wants: ["dessert", "coffee"]),
        .init("between 5 and 7 tomorrow, cheap eats under 8 bucks", day: .tomorrow, from: 17...17, to: 19...19, wants: ["cheap eats|food|eats"], budget: 8),

        // Activities, including ones the model must not invent.
        .init("anything but sushi", avoids: ["sushi"]),
        .init("I'm down for whatever, surprise me"),
        .init("no seafood, no bars, anything else is fine", avoids: ["seafood", "bars"]),
        .init("I'd like to go hiking this weekend, sunday works best", day: .sunday, wants: ["hiking|hike"]),
        .init("I don't want to do dinner, maybe dessert", wants: ["dessert"], avoids: ["dinner"]),
        .init("saturday morning farmers market, avoid anything loud like clubs", day: .saturday, from: 6...10, to: 11...12, wants: ["farmers market|market"], avoids: ["clubs|club|loud"]),
        .init("I'm vegetarian so no steakhouse, want thai food friday", day: .friday, wants: ["thai food|thai"], avoids: ["steakhouse|steak"]),
        .init("budget is 40, sunday afternoon, bowling but not karaoke", day: .sunday, from: 12...13, to: 17...18, wants: ["bowling"], avoids: ["karaoke"], budget: 40),

        // Budgets.
        .init("up for pizza, $10 max, don't share my location", wants: ["pizza"], budget: 10, neverShare: [.place]),
        .init("thursday night drinks, $50 tops, keep where I am private", day: .thursday, from: 18...21, to: lateEnd, wants: ["drinks"], budget: 50, neverShare: [.place]),

        // Never-share, including sentences that mention sharing but allow it.
        .init("keep my budget private, looking for a movie tonight", day: .today, from: evening, to: lateEnd, wants: ["movie"], neverShare: [.budget]),
        .init("don't tell anyone how much I can spend, max 30 dollars, want dinner", wants: ["dinner"], budget: 30, neverShare: [.budget]),
        .init("you can share my schedule, just not my location", neverShare: [.place]),
        .init("fine to share everything, want tacos tonight", day: .today, from: evening, to: lateEnd, wants: ["tacos"]),
        .init("happy to tell people when I'm free. want ice cream after 9 tonight", day: .today, from: 21...21, to: lateEnd, wants: ["ice cream"]),
        .init("never share my location or my schedule", neverShare: [.place, .time]),
        .init("keep my schedule and budget secret", neverShare: [.time, .budget]),
        .init("tell them my budget if needed, want sushi tomorrow at 1", day: .tomorrow, from: 13...13, to: 14...24, wants: ["sushi"]),
    ]
}
