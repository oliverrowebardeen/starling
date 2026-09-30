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

    /// Model output is untrusted: extreme integers must become errors, not
    /// arithmetic traps that crash the app.
    @Test(arguments: [
        RawMove(kind: .counter, budgetDollars: Int.max),
        RawMove(kind: .counter, budgetDollars: Int.min),
        RawMove(kind: .counter, timeOption: Int.min),
        RawMove(kind: .counter, activityOption: Int.min),
        RawMove(kind: .counter, timeOption: Int.max),
    ])
    func extremeIntegersInMovesThrow(raw: RawMove) throws {
        let context = try AgentFixtures.context()
        let prompt = PromptRenderer.decide(context, timeZone: AgentFixtures.utc)
        #expect(throws: AgentModelError.self) { _ = try OutputMapping.move(raw, prompt: prompt, proposal: context.proposal) }
    }

    @Test func extremeIntegersInRulesAreIgnored() throws {
        let context = InterpretationContext(now: AgentFixtures.now, timeZone: AgentFixtures.utc, issues: [])
        let rules = try OutputMapping.rules(RawRules(day: .relative(Int.min), earliestHour: Int.min, latestHour: Int.max, maxDollars: Int.max), context: context)
        #expect(rules.constraints[.budget].isEmpty)
        #expect(rules.constraints[.time] == [try Constraint(.dailyWindow(from: 0, to: 1440))])
    }

    @Test func extremeIntegersInMatchesThrow() throws {
        let wanted = [try Keyword("food")]
        let offered = [try Keyword("boba")]
        #expect(throws: AgentModelError.self) { _ = try OutputMapping.matches([RawMatch(want: Int.min, offer: 1, same: true)], wanted: wanted, offered: offered) }
        #expect(throws: AgentModelError.self) { _ = try OutputMapping.matches([RawMatch(want: 1, offer: Int.min, same: true)], wanted: wanted, offered: offered) }
    }

    /// 2026-11-01 is the US fall-back day: midnight is PDT, the evening is PST.
    /// "18:00 to 20:00" must mean the wall clock, not 18 hours after midnight.
    @Test func interpretedHoursFollowTheWallClockAcrossDaylightSaving() throws {
        let pacific = TimeZone(identifier: "America/Los_Angeles")!
        let noon = Date(timeIntervalSince1970: 1_793_563_200) // 2026-11-01 20:00 UTC, 12:00 PST
        let context = InterpretationContext(now: noon, timeZone: pacific, issues: [])
        let rules = try OutputMapping.rules(RawRules(day: .relative(0), earliestHour: 18, latestHour: 24), context: context)
        let sixPM = Date(timeIntervalSince1970: 1_793_584_800)    // 2026-11-02 02:00 UTC
        let midnight = Date(timeIntervalSince1970: 1_793_606_400) // 2026-11-02 08:00 UTC
        #expect(rules.constraints[.time] == [try Constraint(.within([try TimeSlot(start: sixPM, end: midnight)]))])
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

    @Test func partOfDayFillsHoursOnlyWhenNoneWereStated() throws {
        let context = InterpretationContext(now: AgentFixtures.now, timeZone: AgentFixtures.utc, issues: [])
        let tonight = try OutputMapping.rules(RawRules(day: .relative(0), partOfDay: .evening), context: context)
        #expect(tonight.constraints[.time] == [try Constraint(.within([try AgentFixtures.slot(18, 24)]))])
        // "free after 3 this afternoon": the stated start wins, and the end is open.
        let afterThree = try OutputMapping.rules(RawRules(day: .relative(0), partOfDay: .afternoon, earliestHour: 15), context: context)
        #expect(afterThree.constraints[.time] == [try Constraint(.within([try AgentFixtures.slot(15, 24)]))])
        let morning = try OutputMapping.rules(RawRules(partOfDay: .morning), context: context)
        #expect(morning.constraints[.time] == [try Constraint(.dailyWindow(from: 480, to: 720))])
    }

    /// An end before the start used to drop the whole time constraint,
    /// losing the day the owner named.
    @Test func backwardsWindowKeepsTheDay() throws {
        let context = InterpretationContext(now: AgentFixtures.now, timeZone: AgentFixtures.utc, issues: [])
        let rules = try OutputMapping.rules(RawRules(day: .relative(0), earliestHour: 15, latestHour: 15), context: context)
        #expect(rules.constraints[.time] == [try Constraint(.within([try AgentFixtures.slot(15, 24)]))])
    }

    @Test func zeroBudgetMeansNoLimit() throws {
        let context = InterpretationContext(now: AgentFixtures.now, timeZone: AgentFixtures.utc, issues: [])
        #expect(try OutputMapping.rules(RawRules(maxDollars: 0), context: context).constraints[.budget].isEmpty)
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

@Suite struct ErrorMappingTests {
    @Test func bridgedFrameworkErrorsBecomeUnavailable() {
        let bridged = NSError(domain: "FoundationModels.LanguageModelSession.GenerationError", code: -1)
        guard case .unavailable = FoundationModelsAgent.map(bridged) else {
            Issue.record("expected unavailable")
            return
        }
    }

    @Test func passesThroughAndMapsKnownErrors() {
        #expect(FoundationModelsAgent.map(AgentModelError.guardrailViolation) == .guardrailViolation)
        #expect(FoundationModelsAgent.map(CancellationError()) == .interrupted)
    }
}
