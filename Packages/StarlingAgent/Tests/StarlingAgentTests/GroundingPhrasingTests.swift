@testable import StarlingAgent
import Testing

/// Phrasing families the grounder must preserve. Each row is a correct
/// model output for the phrase (the 24-hour value, and where the model
/// tends to copy it, the 12-hour copy too) and what must survive grounding.
/// Written after two review rounds found edge cases one at a time.
@Suite struct GroundingPhrasingTests {
    struct Hours: Sendable, CustomTestStringConvertible {
        let text: String
        let part: RawRules.PartOfDay?
        let from: Int?, to: Int?
        let expectedFrom: Int?, expectedTo: Int?
        init(_ text: String, _ part: RawRules.PartOfDay?, _ from: Int?, _ to: Int?, _ expectedFrom: Int?, _ expectedTo: Int?) {
            self.text = text
            self.part = part
            self.from = from
            self.to = to
            self.expectedFrom = expectedFrom
            self.expectedTo = expectedTo
        }
        var testDescription: String { "\(text) [\(from.map(String.init) ?? "nil")-\(to.map(String.init) ?? "nil")]" }
    }

    @Test(arguments: [
        // A stated morning keeps small hours in the morning.
        Hours("tomorrow morning after 6", .morning, 6, nil, 6, nil),
        Hours("morning run at 5", .morning, 5, nil, 5, nil),
        Hours("coffee at 8 in the morning", .morning, 8, nil, 8, nil),
        Hours("saturday morning 9 to 11", .morning, 9, 11, 9, 11),
        Hours("breakfast at 7", .morning, 7, nil, 7, nil),
        Hours("free in the am from 6", nil, 6, nil, 6, nil),
        Hours("morning until noon", .morning, nil, 12, nil, 12),
        // Hours with their own am or pm.
        Hours("after 6pm", nil, 6, nil, 18, nil),
        Hours("after 6pm", nil, 18, nil, 18, nil),
        Hours("at 7am", nil, 7, nil, 7, nil),
        Hours("9am to 1pm", nil, 9, 13, 9, 13),
        Hours("9 am to 1 pm", nil, 9, 1, 9, 13),
        Hours("12pm to 2pm", nil, 12, 2, 12, 14),
        // No am or pm: plans with friends default to the afternoon or evening.
        Hours("at 7", nil, 7, nil, 19, nil),
        Hours("free after 3", nil, 3, nil, 15, nil),
        Hours("between 5 and 7", nil, 5, 7, 17, 19),
        Hours("from 9 to 1pm", nil, 9, 1, 9, 13),
        // Named afternoon, evening, tonight.
        Hours("this afternoon at 2", .afternoon, 2, nil, 14, nil),
        Hours("this afternoon at 2", .afternoon, 14, nil, 14, nil),
        Hours("this afternoon until 4", .afternoon, nil, 4, nil, 16),
        Hours("tonight after 8", .evening, 8, nil, 20, nil),
        Hours("tonight after 8", .evening, 20, nil, 20, nil),
        Hours("tonight until 11", .evening, nil, 11, nil, 23),
        Hours("tonight until 11", .evening, nil, 23, nil, 23),
        Hours("evening from 6 to 9", .evening, 6, 9, 18, 21),
        // Noon and midnight.
        Hours("from noon to 3", nil, 12, 3, 12, 15),
        Hours("from noon to 3", nil, 12, 15, 12, 15),
        Hours("until midnight tonight", .evening, nil, 24, nil, 24),
        Hours("until midnight tonight", .evening, nil, 0, nil, 24),
        // Ranges that cross noon.
        Hours("from 10 to 2", nil, 10, 2, 10, 14),
        Hours("from 10 to 2", nil, 10, 14, 10, 14),
        Hours("11 to 1 tomorrow", nil, 11, 1, 11, 13),
        Hours("from 11am to 2", nil, 11, 2, 11, 14),
        Hours("8 to 12", nil, 8, 12, 8, 12),
        // The same hour with both markers keeps each boundary's own marker.
        Hours("today from 6am to 6pm", nil, 6, 18, 6, 18),
        Hours("today from 6am to 6pm", nil, 6, 6, 6, 18),
        Hours("6 am to 6 pm", nil, 6, 6, 6, 18),
        // Clock times with minutes, with and without markers.
        Hours("6:00am to 8:00pm", nil, 6, 20, 6, 20),
        Hours("6:00am to 8:00pm", nil, 6, 8, 6, 20),
        Hours("dinner at 6:30pm", nil, 18, nil, 18, nil),
        Hours("dinner at 6:30pm", nil, 6, nil, 18, nil),
        Hours("run at 6:30am", nil, 6, nil, 6, nil),
        Hours("after 6 p.m.", nil, 6, nil, 18, nil),
        Hours("from 5:45pm to 7:15pm", nil, 17, 19, 17, 19),
        Hours("from 9:30am to 12:30pm", nil, 9, 12, 9, 12),
        Hours("from 6:30 to 8:30", nil, 6, 8, 18, 20),
        Hours("at 7:30", nil, 7, nil, 19, nil),
        Hours("10:00 to 11:00 tomorrow morning", .morning, 10, 11, 10, 11),
        // Already on a 24-hour clock.
        Hours("from 14:00 to 16:00", nil, 14, 16, 14, 16),
        Hours("at 19:30", nil, 19, nil, 19, nil),
    ])
    func hours(_ row: Hours) {
        let checked = Grounding.check(RawRules(partOfDay: row.part, earliestHour: row.from, latestHour: row.to), against: row.text)
        #expect(checked.earliestHour == row.expectedFrom, "start")
        #expect(checked.latestHour == row.expectedTo, "end")
    }

    /// Clock times are found in order with their own markers; amounts are not clock times.
    @Test func clockTimesSkipAmounts() {
        let clocks = Grounding.clockTimes(in: "$15, 15.50, 1,000, 2k, 6:30pm, 6 p.m., 6am, 18:00")
        #expect(clocks.map(\.hour) == [6, 6, 6, 18])
        #expect(clocks.map(\.marker) == ["pm", "pm", "am", nil])
    }

    /// A correct budget from the model must survive grounding.
    @Test(arguments: [
        // Digits, grouped and not.
        ("budget $1,000", 1_000),
        ("under 1,200 dollars", 1_200),
        ("$1,000,000 tops", 1_000_000),
        ("max $15", 15),
        ("$15.50 max", 15),
        ("under 12.99", 12),
        // Currency symbols and words.
        ("15 dollars", 15),
        ("15 bucks", 15),
        ("20$ max", 20),
        ("€20 max", 20),
        ("USD 30", 30),
        ("$1k", 1_000),
        ("2k budget", 2_000),
        // Number words.
        ("twenty five dollars", 25),
        ("budget two hundred dollars", 200),
        ("two hundred and fifty", 250),
        ("a hundred bucks", 100),
        ("fifteen hundred", 1_500),
        ("a thousand dollars", 1_000),
        ("two thousand", 2_000),
        ("one thousand five hundred", 1_500),
        ("three thousand and fifty", 3_050),
    ])
    func budgets(_ text: String, _ dollars: Int) {
        #expect(Grounding.check(RawRules(maxDollars: dollars), against: text).maxDollars == dollars)
    }

    /// The exact numbers read, where grouping could go wrong.
    @Test(arguments: [
        ("budget $1,000", Set([1_000])),
        ("3, 4 or 5 people", Set([3, 4, 5])),
        ("1,5", Set([1, 5])),
        ("$15.50", Set([15])),
        ("10pm, 9:30", Set([10, 9, 30])),
        ("two thousand", Set([2_000])),
    ])
    func numbersRead(_ text: String, _ expected: Set<Int>) {
        #expect(Grounding.numbers(in: Grounding.words(text)) == expected)
    }

    /// A model that rounds "$12.99" up to 13 keeps a cap, at the stated
    /// whole dollars, instead of losing it as ungrounded.
    @Test func centsRoundedUpKeepTheStatedCap() {
        #expect(Grounding.check(RawRules(maxDollars: 13), against: "under 12.99").maxDollars == 12)
        #expect(Grounding.check(RawRules(maxDollars: 16), against: "$15.50 max").maxDollars == 15)
        #expect(Grounding.check(RawRules(maxDollars: 16), against: "$15 max").maxDollars == nil)
    }
}
