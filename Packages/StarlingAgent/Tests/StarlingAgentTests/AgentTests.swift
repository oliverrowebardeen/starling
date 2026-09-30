import Foundation
@testable import StarlingAgent
import StarlingCore
import Testing

enum AgentFixtures {
    static let utc = TimeZone(identifier: "UTC")!
    /// Tuesday 2026-09-29 12:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_790_683_200)

    static func slot(_ from: Double, _ to: Double) throws -> TimeSlot {
        let midnight = Date(timeIntervalSince1970: 1_790_640_000)
        return try TimeSlot(start: midnight.addingTimeInterval(from * 3600), end: midnight.addingTimeInterval(to * 3600))
    }

    static func constraints() throws -> ConstraintSet {
        try ConstraintSet([
            .time: [try Constraint(.within([try slot(18, 23)]))],
            .activity: [try Constraint(.prefers(liked: [try Keyword("boba")], avoided: [try Keyword("sushi")]), strength: .soft)],
            .budget: [try Constraint(.atMost(try MoneyAmount(minorUnits: 1200)))],
        ])
    }

    static func proposal() throws -> Proposal {
        try Proposal(round: 0, terms: Terms([
            .time: .slots([try slot(19, 21)]),
            .activity: .keywords([try Keyword("sushi")]),
            .budget: .amount(try MoneyAmount(minorUnits: 1500)),
        ]))
    }

    static func context() throws -> NegotiationContext {
        NegotiationContext(proposal: try proposal(), constraints: try constraints(), history: [], now: now)
    }
}

@Suite struct PromptRendererTests {
    @Test func rendersLimitsProposalConflictsAndNumberedOptions() throws {
        let prompt = PromptRenderer.decide(try AgentFixtures.context(), timeZone: AgentFixtures.utc)
        #expect(prompt.text == """
            Owner limits:
            - activity: likes boba; avoids sushi (flexible)
            - budget: at most $12
            - time: Tue 18:00-23:00
            Proposal (round 1):
            - activity: sushi BREAKS LIMIT
            - budget: $15 BREAKS LIMIT
            - time: Tue 19:00-21:00
            Time options: 1) Tue 18:00-23:00 2) Tue 19:00-21:00
            Activity options: 1) boba 2) sushi
            """)
        #expect(prompt.timeOptions.count == 2)
        #expect(prompt.activityOptions.map(\.value) == ["boba", "sushi"])
    }

    @Test func capsOptionLists() throws {
        let many = try (0..<20).map { try Keyword("thing \($0)") }
        let constraints = try ConstraintSet([.activity: [try Constraint(.prefers(liked: Array(many.prefix(16)), avoided: []))]])
        let proposal = try Proposal(round: 0, terms: Terms([.activity: .keywords(Array(many.suffix(4)))]))
        let prompt = PromptRenderer.decide(NegotiationContext(proposal: proposal, constraints: constraints, history: [], now: AgentFixtures.now), timeZone: AgentFixtures.utc)
        #expect(prompt.activityOptions.count == PromptRenderer.maxActivityOptions)
    }

    @Test func formatsMoney() throws {
        #expect(PromptRenderer.money(try MoneyAmount(minorUnits: 1500)) == "$15")
        #expect(PromptRenderer.money(try MoneyAmount(minorUnits: 1250)) == "$12.50")
        #expect(PromptRenderer.money(try MoneyAmount(minorUnits: 900, currency: "EUR")) == "9 EUR")
    }
}

@Suite struct OutputMappingTests {
    @Test func countersUseOnlyOfferedOptions() throws {
        let context = try AgentFixtures.context()
        let prompt = PromptRenderer.decide(context, timeZone: AgentFixtures.utc)
        let move = try OutputMapping.move(RawMove(kind: .counter, timeOption: 1, activityOption: 1, budgetDollars: 12), prompt: prompt, proposal: context.proposal)
        #expect(move == .counter(try Terms([
            .time: .slots([try AgentFixtures.slot(18, 23)]),
            .activity: .keywords([try Keyword("boba")]),
            .budget: .amount(try MoneyAmount(minorUnits: 1200)),
        ])))
    }

    @Test(arguments: [
        RawMove(kind: .counter, timeOption: 3),
        RawMove(kind: .counter, activityOption: 0),
        RawMove(kind: .counter, budgetDollars: -5),
        RawMove(kind: .counter),
    ])
    func rejectsInventedOrEmptyCounters(raw: RawMove) throws {
        let context = try AgentFixtures.context()
        let prompt = PromptRenderer.decide(context, timeZone: AgentFixtures.utc)
        #expect(throws: AgentModelError.self) { _ = try OutputMapping.move(raw, prompt: prompt, proposal: context.proposal) }
    }

    @Test func mapsRulesWithNamedWeekdays() throws {
        let context = InterpretationContext(now: AgentFixtures.now, timeZone: AgentFixtures.utc, issues: [])
        let raw = RawRules(day: .weekday(7), earliestHour: 13, latestHour: 17, wants: ["Boba", "bad:word"], avoids: ["sushi"], maxDollars: 20, neverShare: [.location])
        let rules = try OutputMapping.rules(raw, context: context)
        // Tuesday to Saturday is four days.
        let saturday = Date(timeIntervalSince1970: 1_790_640_000 + 4 * 86_400)
        #expect(rules.constraints[.time] == [try Constraint(.within([try TimeSlot(start: saturday.addingTimeInterval(13 * 3600), end: saturday.addingTimeInterval(17 * 3600))]))])
        #expect(rules.constraints[.activity] == [try Constraint(.prefers(liked: [try Keyword("boba")], avoided: [try Keyword("sushi")]), strength: .soft)])
        #expect(rules.constraints[.budget] == [try Constraint(.atMost(try MoneyAmount(minorUnits: 2000)))])
        #expect(rules.disclosure == [DisclosureRule(issue: .place, action: .never)])
    }

    @Test func hoursWithoutADayBecomeADailyWindow() throws {
        let context = InterpretationContext(now: AgentFixtures.now, timeZone: AgentFixtures.utc, issues: [])
        let rules = try OutputMapping.rules(RawRules(earliestHour: 10), context: context)
        #expect(rules.constraints[.time] == [try Constraint(.dailyWindow(from: 600, to: 1440))])
    }

    @Test func matchesValidateIndicesAndDeduplicate() throws {
        let wanted = [try Keyword("food")]
        let offered = [try Keyword("boba run"), try Keyword("movie")]
        let matches = try OutputMapping.matches([RawMatch(want: 1, offer: 1, same: false), RawMatch(want: 1, offer: 1, same: false)], wanted: wanted, offered: offered)
        #expect(matches == [KeywordMatch(wanted: wanted[0], offered: offered[0], strength: .satisfies)])
        #expect(throws: AgentModelError.self) { _ = try OutputMapping.matches([RawMatch(want: 2, offer: 1, same: true)], wanted: wanted, offered: offered) }
    }
}

@Suite struct HardLimitsTests {
    @Test func flagsBudgetTimeAndAvoidedKeywords() throws {
        let violations = HardLimits.violations(of: try AgentFixtures.proposal().terms, against: try AgentFixtures.constraints(), timeZone: AgentFixtures.utc)
        #expect(violations == ["activity: includes an avoided keyword", "budget: over budget"])
    }

    @Test func flagsSlotsOutsideWindows() throws {
        let terms = try Terms([.time: .slots([try AgentFixtures.slot(22, 24)])])
        #expect(HardLimits.violations(of: terms, against: try AgentFixtures.constraints(), timeZone: AgentFixtures.utc) == ["time: outside available time"])
    }
}
