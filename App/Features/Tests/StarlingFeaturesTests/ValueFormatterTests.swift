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
}
