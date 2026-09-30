import Foundation
import StarlingCore
import StarlingFeatures
import Testing

@Suite struct RulesDraftTests {
    static func sampleRules() throws -> OwnerRules {
        let tonight = try TimeSlot(startMinute: 29_000_000, endMinute: 29_000_240)
        return OwnerRules(
            constraints: try ConstraintSet([
                .time: [try Constraint(.within([tonight])), try Constraint(.dailyWindow(from: 600, to: 1440), strength: .soft)],
                .activity: [try Constraint(.prefers(liked: [try Keyword("food")], avoided: [try Keyword("sushi")]))],
                .budget: [try Constraint(.atMost(try MoneyAmount(minorUnits: 1500)))],
                .partySize: [try Constraint(.countBetween(min: 2, max: 4))],
                .diet: [try Constraint(.mustBe(true))],
            ]),
            disclosure: [DisclosureRule(issue: .place, action: .never)]
        )
    }

    @Test func roundTripsEveryRuleKind() throws {
        let rules = try Self.sampleRules()
        let draft = RulesDraft(rules)
        #expect(draft.problems.isEmpty)
        #expect(try draft.build() == rules)
    }

    @Test func editsChangeTheBuiltRules() throws {
        var draft = RulesDraft(try Self.sampleRules())
        let budget = try #require(draft.items.firstIndex { $0.kind == .atMost })
        draft.items[budget].amountMinorUnits = 2000
        draft.items.removeAll { $0.kind == .prefers }
        draft.sharing[0].action = .askEachTime

        let built = try draft.build()
        #expect(built.constraints[.budget] == [try Constraint(.atMost(try MoneyAmount(minorUnits: 2000)))])
        #expect(built.constraints[.activity].isEmpty)
        #expect(built.disclosure == [DisclosureRule(issue: .place, action: .askEachTime)])
    }

    @Test func keywordsAreEditedAsCommaSeparatedText() throws {
        var draft = RulesDraft.empty
        draft.add(.prefers, issue: .activity)
        draft.items[0].likedText = "Boba run,  tacos ,"
        draft.items[0].avoidedText = ""
        let built = try draft.build()
        #expect(built.constraints[.activity] == [try Constraint(.prefers(liked: [try Keyword("boba run"), try Keyword("tacos")], avoided: []))])
    }

    @Test func amountsAreEditedInMajorUnits() throws {
        var draft = RulesDraft.empty
        draft.add(.atMost, issue: .budget)
        draft.items[0].amount = Decimal(string: "15.505")!
        #expect(draft.items[0].amountMinorUnits == 1551)
        #expect(draft.items[0].amount == Decimal(string: "15.51")!)
        draft.items[0].currency = "JPY"
        draft.items[0].amount = 1200
        #expect(draft.items[0].amountMinorUnits == 1200)
    }

    @Test func reportsProblemsPerItemInsteadOfBuilding() throws {
        var draft = RulesDraft.empty
        draft.add(.dailyWindow, issue: .time)
        draft.items[0].fromMinute = 900
        draft.items[0].toMinute = 600
        draft.add(.prefers, issue: .activity)
        draft.items[1].likedText = "pizza!"
        draft.add(.countBetween, issue: .partySize)
        draft.items[2].minCount = 5
        draft.items[2].maxCount = 2

        let problems = draft.problems
        #expect(Set(problems.compactMap(\.itemID)) == Set(draft.items.map(\.id)))
        #expect(throws: RulesDraftError.self) { try draft.build() }
    }

    @Test func emptyPreferenceIsAProblem() {
        var draft = RulesDraft.empty
        draft.add(.prefers, issue: .activity)
        #expect(draft.problems.count == 1)
    }

    @Test func twoSharingRulesForOneIssueIsAProblem() {
        var draft = RulesDraft.empty
        draft.addSharing(issue: .place)
        draft.addSharing(issue: .place)
        #expect(draft.problems.count == 1)
    }

    @Test func tooManyRulesOnOneIssueIsAProblem() {
        var draft = RulesDraft.empty
        for _ in 0...ConstraintSet.maxConstraintsPerIssue { draft.add(.mustBe, issue: .diet) }
        #expect(!draft.problems.isEmpty)
    }
}

@Suite struct ReviewFlagTests {
    func draft(from rules: OwnerRules) -> RulesDraft { RulesDraft(rules, origin: .model) }

    @Test func flagsKeywordsTheOwnerNeverWrote() throws {
        let rules = OwnerRules(constraints: try ConstraintSet([
            .activity: [try Constraint(.prefers(liked: [try Keyword("food"), try Keyword("karaoke")], avoided: []))],
        ]))
        let draft = draft(from: rules)
        let flags = draft.reviewFlags(for: "free tonight, want food")
        #expect(flags[draft.items[0].id]?.contains("karaoke") == true)
        #expect(flags[draft.items[0].id]?.contains("food") == false)
    }

    @Test func toleratesPluralsWhenTracingKeywords() throws {
        let rules = OwnerRules(constraints: try ConstraintSet([
            .activity: [try Constraint(.prefers(liked: [try Keyword("taco")], avoided: []))],
        ]))
        #expect(draft(from: rules).reviewFlags(for: "tacos tonight").isEmpty)
    }

    @Test func flagsAmountsTheOwnerNeverWrote() throws {
        let rules = OwnerRules(constraints: try ConstraintSet([
            .budget: [try Constraint(.atMost(try MoneyAmount(minorUnits: 2500)))],
        ]))
        let draft = draft(from: rules)
        #expect(draft.reviewFlags(for: "under $15").count == 1)
        #expect(draft.reviewFlags(for: "under $25").isEmpty)
    }

    @Test func flagsDailyWindowHoursTheOwnerNeverWrote() throws {
        let rules = OwnerRules(constraints: try ConstraintSet([
            .time: [try Constraint(.dailyWindow(from: 600, to: 1440))],
        ]))
        let draft = draft(from: rules)
        #expect(draft.reviewFlags(for: "no plans before 10").isEmpty)
        #expect(draft.reviewFlags(for: "no plans before 9").count == 1)
    }

    @Test func flagsPermissiveSharingEvenWhenWritten() {
        let draft = draft(from: OwnerRules(constraints: .empty, disclosure: [
            DisclosureRule(issue: .time, action: .allowOnDevicePeers),
            DisclosureRule(issue: .place, action: .never),
        ]))
        let flags = draft.reviewFlags(for: "share my times")
        #expect(flags.keys.contains(draft.sharing[0].id))
        #expect(!flags.keys.contains(draft.sharing[1].id))
    }

    @Test func neverFlagsWhatTheOwnerAddedByHand() {
        var draft = RulesDraft.empty
        draft.add(.atMost, issue: .budget)
        draft.addSharing(issue: .time)
        draft.sharing[0].action = .allowOnDevicePeers
        #expect(draft.reviewFlags(for: "anything").isEmpty)
    }
}

@Suite struct RulesMergeTests {
    @Test func intentConstraintsAddToStandingOnes() throws {
        let standing = OwnerRules(constraints: try ConstraintSet([.time: [try Constraint(.dailyWindow(from: 600, to: 1440))]]))
        let slot = try TimeSlot(startMinute: 100, endMinute: 200)
        let intent = OwnerRules(constraints: try ConstraintSet([.time: [try Constraint(.within([slot]))]]))
        let merged = try RulesMerge.intent(intent, standing: standing)
        #expect(merged.constraints[.time] == standing.constraints[.time] + intent.constraints[.time])
    }

    @Test func mostRestrictiveSharingRuleWins() throws {
        let standing = OwnerRules(constraints: .empty, disclosure: [
            DisclosureRule(issue: .place, action: .never),
            DisclosureRule(issue: .time, action: .askEachTime),
        ])
        let intent = OwnerRules(constraints: .empty, disclosure: [
            DisclosureRule(issue: .place, action: .allowOnDevicePeers),
            DisclosureRule(issue: .budget, action: .allowOnDevicePeers),
        ])
        let merged = try RulesMerge.intent(intent, standing: standing)
        #expect(merged.disclosure == [
            DisclosureRule(issue: .budget, action: .allowOnDevicePeers),
            DisclosureRule(issue: .place, action: .never),
            DisclosureRule(issue: .time, action: .askEachTime),
        ])
    }

    @Test func mergeThatBreaksALimitThrows() throws {
        let many = try (0..<ConstraintSet.maxConstraintsPerIssue).map { _ in try Constraint(.mustBe(true)) }
        let standing = OwnerRules(constraints: try ConstraintSet([.diet: many]))
        let intent = OwnerRules(constraints: try ConstraintSet([.diet: [try Constraint(.mustBe(false))]]))
        #expect(throws: ValidationError.self) { try RulesMerge.intent(intent, standing: standing) }
    }
}
