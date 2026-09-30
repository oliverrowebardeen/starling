import Foundation
import StarlingCore
import Testing

@Suite struct HardLimitsTests {
    let utc = TimeZone(identifier: "UTC")!

    func slot(_ from: Int64, _ to: Int64) throws -> TimeSlot {
        // 2026-09-29 00:00 UTC is minute 29_838_240.
        try TimeSlot(startMinute: 29_838_240 + from * 60, endMinute: 29_838_240 + to * 60)
    }

    func constraints() throws -> ConstraintSet {
        try ConstraintSet([
            .time: [try Constraint(.within([try slot(18, 23)])), try Constraint(.dailyWindow(from: 600, to: 1380))],
            .activity: [try Constraint(.prefers(liked: [try Keyword("boba")], avoided: [try Keyword("sushi")]), strength: .soft)],
            .budget: [try Constraint(.atMost(try MoneyAmount(minorUnits: 1200)))],
            .partySize: [try Constraint(.countBetween(min: 2, max: 4))],
        ])
    }

    @Test func compliantTermsHaveNoViolations() throws {
        let terms = try Terms([
            .time: .slots([try slot(19, 21)]),
            .activity: .keywords([try Keyword("boba")]),
            .budget: .amount(try MoneyAmount(minorUnits: 1200)),
            .partySize: .count(3),
        ])
        #expect(try constraints().violations(of: terms, timeZone: utc).isEmpty)
    }

    @Test func reportsEachKindOfViolationInOrder() throws {
        let terms = try Terms([
            .time: .slots([try slot(22, 24)]),
            .activity: .keywords([try Keyword("sushi")]),
            .budget: .amount(try MoneyAmount(minorUnits: 1500)),
            .partySize: .count(9),
        ])
        #expect(try constraints().violations(of: terms, timeZone: utc) == [
            LimitViolation(issue: .activity, reason: .avoidedKeyword),
            LimitViolation(issue: .budget, reason: .overBudget),
            LimitViolation(issue: .partySize, reason: .countOutOfRange),
            LimitViolation(issue: .time, reason: .outsideAvailableTime),
            LimitViolation(issue: .time, reason: .outsideDailyWindow),
        ])
    }

    @Test func missingIssuesAndOtherCurrenciesAreNotViolations() throws {
        let terms = try Terms([.budget: .amount(try MoneyAmount(minorUnits: 99_999, currency: "EUR"))])
        #expect(try constraints().violations(of: terms, timeZone: utc).isEmpty)
    }

    @Test func descriptionsAreStable() {
        #expect(LimitViolation(issue: .budget, reason: .overBudget).description == "budget: over budget")
        #expect(LimitViolation(issue: .activity, reason: .avoidedKeyword).description == "activity: includes an avoided keyword")
    }
}
