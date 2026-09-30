@testable import StarlingAgent
import Testing

/// Each case is a real model output from the Phase 1 labeled-set runs,
/// trimmed to the field under test.
@Suite struct GroundingTests {
    @Test func dropsInventedActivitiesAndRuleFragments() {
        let raw = RawRules(wants: ["coffee", "sandwich", "ice cream"], avoids: ["sushi"])
        #expect(Grounding.check(raw, against: "saturday afternoon works, anything but sushi").wants == [])

        let fragments = RawRules(wants: ["food", "under $15", "not far"])
        #expect(Grounding.check(fragments, against: "free tonight, want food, under $15, not far").wants == ["food"])

        let sharing = RawRules(wants: ["share schedule", "surprise me", "5", "none"])
        #expect(Grounding.check(sharing, against: "you can share my schedule, surprise me, until 5, none").wants == [])
    }

    @Test func keepsActivitiesTheOwnerNamed() {
        let raw = RawRules(wants: ["hike", "boba run", "cheap eats", "tacos"])
        let checked = Grounding.check(raw, against: "hiking sunday, boba or taco, cheap eats")
        #expect(checked.wants == ["hike", "boba run", "cheap eats", "tacos"])
    }

    @Test func avoidsLoseTheirNegationInsteadOfBeingDropped() {
        let raw = RawRules(avoids: ["no seafood", "no bars", "none"])
        #expect(Grounding.check(raw, against: "no seafood, no bars, anything else is fine").avoids == ["seafood", "bars"])
    }

    @Test func budgetMustBeStated() {
        #expect(Grounding.check(RawRules(maxDollars: 15), against: "under $15").maxDollars == 15)
        #expect(Grounding.check(RawRules(maxDollars: 20), against: "not spending more than twenty").maxDollars == 20)
        #expect(Grounding.check(RawRules(maxDollars: 25), against: "under twenty five dollars").maxDollars == 25)
        #expect(Grounding.check(RawRules(maxDollars: 10), against: "cheap eats please").maxDollars == nil)
    }

    @Test func neverShareNeedsAPrivacyWordAndTheField() {
        let all: [RawRules.Shareable] = [.location, .schedule, .budget]
        #expect(Grounding.check(RawRules(neverShare: all), against: "down for boba after 8 tonight, don't tell people my schedule").neverShare == [.schedule])
        #expect(Grounding.check(RawRules(neverShare: all), against: "thursday night drinks, $50 tops, keep where I am private").neverShare == [.location])
        #expect(Grounding.check(RawRules(neverShare: all), against: "free wednesday evening, want to study at the library").neverShare == [])
        #expect(Grounding.check(RawRules(neverShare: all), against: "don't tell anyone how much I can spend").neverShare == [.budget])
        #expect(Grounding.check(RawRules(neverShare: all), against: "never share my location or my schedule").neverShare == [.location, .schedule])
    }

    @Test func dayMustBeNamed() {
        #expect(Grounding.check(RawRules(day: .relative(0)), against: "anything but sushi").day == nil)
        #expect(Grounding.check(RawRules(day: .relative(0)), against: "movie tonight").day == .relative(0))
        #expect(Grounding.check(RawRules(day: .relative(1)), against: "coffee tomorrow").day == .relative(1))
        #expect(Grounding.check(RawRules(day: .weekday(6)), against: "thai food friday").day == .weekday(6))
        #expect(Grounding.check(RawRules(day: .weekday(1)), against: "hiking this weekend").day == .weekday(1))
        #expect(Grounding.check(RawRules(day: .weekday(2)), against: "hiking this weekend").day == nil)
    }

    @Test func partOfDayMustBeNamed() {
        #expect(Grounding.check(RawRules(partOfDay: .evening), against: "max 30 dollars, want dinner").partOfDay == nil)
        #expect(Grounding.check(RawRules(partOfDay: .evening), against: "movie tonight").partOfDay == .evening)
        #expect(Grounding.check(RawRules(partOfDay: .lunch), against: "sunday brunch").partOfDay == .lunch)
    }

    @Test(arguments: [
        // (model start, model end, part of day, utterance, expected start, expected end)
        HourCase(3, 3, nil, "free after class at 3 today", 15, nil),
        HourCase(7, 10, .evening, "friday between 7 and 10pm", 19, 22),
        HourCase(5, 7, nil, "between 5 and 7 tomorrow", 17, 19),
        HourCase(1, 12, .morning, "sushi tomorrow at 1", 13, nil),
        HourCase(9, nil, nil, "saturday, not before 9am", 9, nil),
        HourCase(11, 23, nil, "any time after 11am works", 11, nil),
        HourCase(12, 17, .afternoon, "saturday afternoon works", nil, nil),
        HourCase(12, nil, nil, "nothing before noon", 12, nil),
        HourCase(0, 23, nil, "no seafood, no bars", nil, nil),
    ])
    func hoursAreStatedAndOnATwentyFourHourClock(_ test: HourCase) {
        let raw = RawRules(partOfDay: test.part, earliestHour: test.from, latestHour: test.to)
        let checked = Grounding.check(raw, against: test.text)
        #expect(checked.earliestHour == test.expectedFrom, "\(test.text)")
        #expect(checked.latestHour == test.expectedTo, "\(test.text)")
    }

    @Test func readsNumbersInDigitsAndWords() {
        #expect(Grounding.numbers(in: Grounding.words("$15, 10pm, twenty five, eight, noon")) == [15, 10, 25, 8])
    }

    struct HourCase: Sendable, CustomTestStringConvertible {
        let from: Int?, to: Int?, part: RawRules.PartOfDay?, text: String, expectedFrom: Int?, expectedTo: Int?
        init(_ from: Int?, _ to: Int?, _ part: RawRules.PartOfDay?, _ text: String, _ expectedFrom: Int?, _ expectedTo: Int?) {
            self.from = from
            self.to = to
            self.part = part
            self.text = text
            self.expectedFrom = expectedFrom
            self.expectedTo = expectedTo
        }
        var testDescription: String { text }
    }
}
