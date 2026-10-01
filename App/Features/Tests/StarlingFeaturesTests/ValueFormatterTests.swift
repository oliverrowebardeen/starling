import Foundation
import StarlingCore
import StarlingFeatures
import Testing

@Suite struct ValueFormatterTests {
    let formatter = ValueFormatter(timeZone: TimeZone(identifier: "UTC")!, locale: Locale(identifier: "en_US"))

    @Test func namesKnownIssuesInPlainWords() throws {
        #expect(formatter.issueName(.time) == "Time")
        #expect(formatter.issueName(.partySize) == "Group size")
        #expect(formatter.issueName(try IssueKey("walking_distance")) == "Walking distance")
    }

    @Test func formatsMoneyInItsCurrency() throws {
        let fifteen = try MoneyAmount(minorUnits: 1500)
        #expect(formatter.money(fifteen) == "$15.00")
    }

    @Test func formatsMinutesOfDayWithMidnightAtBothEnds() {
        #expect(formatter.minutesOfDay(0) == "midnight")
        #expect(formatter.minutesOfDay(1440) == "midnight")
        #expect(formatter.minutesOfDay(600).contains("10:00"))
    }

    @Test func describesEveryRuleKind() throws {
        let food = try Keyword("food")
        let sushi = try Keyword("sushi")
        #expect(formatter.rule(.dailyWindow(from: 600, to: 1440)).hasPrefix("Between 10:00"))
        #expect(formatter.rule(.atMost(try MoneyAmount(minorUnits: 1500))) == "At most $15.00")
        #expect(formatter.rule(.atLeast(try MoneyAmount(minorUnits: 500))) == "At least $5.00")
        #expect(formatter.rule(.prefers(liked: [food], avoided: [sushi])) == "Likes food. Avoids sushi.")
        #expect(formatter.rule(.prefers(liked: [], avoided: [sushi])) == "Avoids sushi.")
        #expect(formatter.rule(.mustBe(true)) == "Must be yes")
        #expect(formatter.rule(.countBetween(min: 2, max: 4)) == "Between 2 and 4")
        let slot = try TimeSlot(startMinute: 0, endMinute: 60)
        #expect(formatter.rule(.within([slot])).hasPrefix("Only "))
    }

    @Test func marksSoftConstraintsAsFlexible() throws {
        let soft = try Constraint(.mustBe(false), strength: .soft)
        #expect(formatter.constraint(soft) == "Must be no (flexible)")
    }

    @Test func describesPeerModelLocalityAsSelfDeclared() {
        #expect(formatter.locality(.onDevice).contains("their iPhone"))
        #expect(formatter.locality(.thirdPartyCloud(provider: "acme")).contains("acme"))
    }

    @Test func describesDisclosedItemsWithTheirValues() throws {
        let budget = DisclosedItem(category: .terms, issue: .budget, value: .amount(try MoneyAmount(minorUnits: 1500)))
        let line = formatter.disclosedItem(budget)
        #expect(line.title == "Budget")
        #expect(line.detail == "$15.00")

        let psi = formatter.disclosedItem(DisclosedItem(category: .psi, issue: .time, value: nil))
        #expect(psi.title == "Matching step over your free times")
    }

    @Test func listsTermsInIssueOrder() throws {
        let terms = try Terms([
            .budget: .amount(try MoneyAmount(minorUnits: 1500)),
            .activity: .keywords([try Keyword("food")]),
        ])
        let lines = formatter.terms(terms)
        #expect(lines.map(\.title) == ["Activity", "Budget"])
        #expect(lines.map(\.detail) == ["food", "$15.00"])
    }

    /// Re-review finding 2 on PR #15: absolute slots must carry their date,
    /// or slots a week apart read the same on consent sheets and matches.
    @Test func slotsAWeekApartReadDifferently() throws {
        // Tuesday 2026-09-29 19:00 UTC, and the same time a week later.
        let start = Int64(1_790_708_400 / 60)
        let first = try TimeSlot(startMinute: start, endMinute: start + 240)
        let second = try TimeSlot(startMinute: start + 7 * 24 * 60, endMinute: start + 7 * 24 * 60 + 240)
        let formatter = ValueFormatter(timeZone: Fixtures.utc, locale: Locale(identifier: "en_US"), referenceDate: { Fixtures.noon })
        #expect(formatter.slot(first) != formatter.slot(second))
        #expect(formatter.slot(first).contains("Sep 29"))
        #expect(formatter.slot(second).contains("Oct 6"))
    }

    @Test func aSlotCrossingMidnightNamesBothDates() throws {
        let start = Int64(1_790_708_400 / 60) + 4 * 60 // 23:00
        let slot = try TimeSlot(startMinute: start, endMinute: start + 120)
        let formatter = ValueFormatter(timeZone: Fixtures.utc, locale: Locale(identifier: "en_US"), referenceDate: { Fixtures.noon })
        #expect(formatter.slot(slot).contains("Sep 29"))
        #expect(formatter.slot(slot).contains("Sep 30"))
    }

    @Test func aSlotInAnotherYearShowsTheYear() throws {
        let start = Int64(1_790_708_400 / 60) + 365 * 24 * 60
        let slot = try TimeSlot(startMinute: start, endMinute: start + 60)
        let formatter = ValueFormatter(timeZone: Fixtures.utc, locale: Locale(identifier: "en_US"), referenceDate: { Fixtures.noon })
        #expect(formatter.slot(slot).contains("2027"))
        #expect(!ValueFormatter(timeZone: Fixtures.utc, locale: Locale(identifier: "en_US"), referenceDate: { Fixtures.noon })
            .slot(try TimeSlot(startMinute: Int64(1_790_708_400 / 60), endMinute: Int64(1_790_708_400 / 60) + 60)).contains("2026"))
    }
}
