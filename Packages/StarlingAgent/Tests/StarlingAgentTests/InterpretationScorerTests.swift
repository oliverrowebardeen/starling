import Foundation
@testable import StarlingAgent
@testable import StarlingAgentBench
import StarlingCore
import StarlingFakes
import Testing

@Suite struct InterpretationScorerTests {
    static let context = InterpretationContext(now: InterpretationSet.now, timeZone: InterpretationSet.timeZone, issues: [.time, .activity, .budget])

    /// A scripted model that answers every labeled utterance perfectly.
    static let oracle = ScriptedAgentModel(
        usage: TokenUsage(inputTokens: 400, outputTokens: 40),
        onInterpret: { utterance, context in
            guard let label = InterpretationSet.labels.first(where: { $0.text == utterance.text }) else { throw AgentModelError.unsupported }
            return try label.rules(context: context)
        }
    )

    @Test func setIsLargeEnoughAndValid() throws {
        #expect(InterpretationSet.labels.count >= 30)
        #expect(Set(InterpretationSet.labels.map(\.text)).count == InterpretationSet.labels.count)
        for label in InterpretationSet.labels {
            _ = try OwnerUtterance(label.text)
            #expect(label.from.lowerBound >= 0 && label.to.upperBound <= 24, "\(label.text)")
        }
        // Every field the plan names is exercised by some label.
        let labels = InterpretationSet.labels
        #expect(labels.contains { $0.day != nil })
        #expect(labels.contains { $0.from != 0...0 })
        #expect(labels.contains { !$0.wants.isEmpty })
        #expect(labels.contains { !$0.avoids.isEmpty })
        #expect(labels.contains { $0.budget != nil })
        #expect(labels.contains { !$0.neverShare.isEmpty })
    }

    @Test func oracleScoresEveryFieldCorrect() async throws {
        let report = await InterpretationEval(model: Self.oracle).run()
        #expect(report.errors == 0)
        for field in InterpretationField.allCases {
            #expect(report.accuracy(field) == 1, "\(field)")
        }
        #expect(report.exact == InterpretationSet.labels.count)
        #expect(report.worstTokens == 440)
    }

    /// The Phase 0 failure modes, scripted: every never-share flag set, an
    /// invented activity, and no budget.
    @Test func detectsThePhaseZeroFailureModes() async throws {
        let model = ScriptedAgentModel(onInterpret: { utterance, context in
            guard let label = InterpretationSet.labels.first(where: { $0.text == utterance.text }) else { throw AgentModelError.unsupported }
            let perfect = try label.rules(context: context)
            var constraints = perfect.constraints.constraints
            constraints[.budget] = nil
            let liked = (constraints[.activity]?.first).flatMap { c -> [Keyword]? in
                if case .prefers(let liked, _) = c.rule { return liked } else { return nil }
            } ?? []
            let avoided = (constraints[.activity]?.first).flatMap { c -> [Keyword]? in
                if case .prefers(_, let avoided) = c.rule { return avoided } else { return nil }
            } ?? []
            constraints[.activity] = [try Constraint(.prefers(liked: liked + [try Keyword("walk")], avoided: avoided), strength: .soft)]
            return OwnerRules(
                constraints: try ConstraintSet(constraints),
                disclosure: [.place, .time, .budget].map { DisclosureRule(issue: $0, action: .never) }
            )
        })
        let report = await InterpretationEval(model: model).run()
        let labels = InterpretationSet.labels
        #expect(report.accuracy(.wants) == 0)
        #expect(report.inventedWants == labels.count)
        #expect(report.droppedBudgets == labels.filter { $0.budget != nil }.count)
        #expect(report.correct(.budget) == labels.filter { $0.budget == nil }.count)
        #expect(report.extraNeverShare == labels.map { 3 - $0.neverShare.count }.reduce(0, +))
        #expect(report.missedNeverShare == 0)
        #expect(report.accuracy(.days) == 1)
        #expect(report.accuracy(.times) == 1)
        #expect(report.accuracy(.avoids) == 1)
        let markdown = report.markdown()
        #expect(markdown.contains("| budget | \(report.correct(.budget)) / \(labels.count) |"))
        #expect(markdown.contains("| Invented activities | \(labels.count) |"))
    }

    @Test func failedCallsScoreZeroAndCountMissedNeverShare() async throws {
        let report = await InterpretationEval(model: ScriptedAgentModel()).run()
        #expect(report.errors == InterpretationSet.labels.count)
        #expect(report.exact == 0)
        #expect(report.missedNeverShare == InterpretationSet.labels.map(\.neverShare.count).reduce(0, +))
    }

    @Test func extractsFieldsFromSlotsAndDailyWindows() throws {
        let tonight = InterpretationLabel("x", day: .today, from: 20...20, to: 24...24, wants: ["boba"], budget: 12, neverShare: [.time])
        let fields = InterpretedFields(try tonight.rules(context: Self.context), now: InterpretationSet.now, timeZone: InterpretationSet.timeZone)
        #expect(fields == InterpretedFields(dayOffset: 0, fromHour: 20, toHour: 24, wants: ["boba"], maxDollars: 12, neverShare: ["time"]))

        let daily = InterpretationLabel("x", from: 10...10)
        let dailyFields = InterpretedFields(try daily.rules(context: Self.context), now: InterpretationSet.now, timeZone: InterpretationSet.timeZone)
        #expect(dailyFields == InterpretedFields(fromHour: 10, toHour: 24))

        let saturday = InterpretationLabel("x", day: .saturday)
        #expect(saturday.dayOffset(now: InterpretationSet.now, timeZone: InterpretationSet.timeZone) == 4)
        #expect(InterpretationLabel("x", day: .tuesday).dayOffset(now: InterpretationSet.now, timeZone: InterpretationSet.timeZone) == 0)
        #expect(InterpretationLabel("x", day: .monday).dayOffset(now: InterpretationSet.now, timeZone: InterpretationSet.timeZone) == 6)
    }

    @Test func keywordComparisonIsLenientButCatchesInventions() {
        #expect(InterpretationScorer.compare(expected: ["boba"], actual: ["boba run"]) == ([], []))
        #expect(InterpretationScorer.compare(expected: ["tacos"], actual: ["taco"]) == ([], []))
        #expect(InterpretationScorer.compare(expected: ["hiking|hike"], actual: ["hike"]) == ([], []))
        #expect(InterpretationScorer.compare(expected: ["study|library"], actual: ["study", "library"]) == ([], []))
        #expect(InterpretationScorer.compare(expected: [], actual: ["walk", "coffee"]) == ([], ["walk", "coffee"]))
        #expect(InterpretationScorer.compare(expected: ["food"], actual: ["not far"]) == (["food"], ["not far"]))
    }

    @Test func tolerancesAcceptVagueHours() {
        let label = InterpretationLabel("free tonight", day: .today, from: 17...20, to: 22...24)
        let fine = InterpretationScorer.score(label, actual: InterpretedFields(dayOffset: 0, fromHour: 18, toHour: 23), now: InterpretationSet.now, timeZone: InterpretationSet.timeZone)
        #expect(fine.correct.isSuperset(of: [.days, .times]))
        let early = InterpretationScorer.score(label, actual: InterpretedFields(dayOffset: 0, fromHour: 15, toHour: 23), now: InterpretationSet.now, timeZone: InterpretationSet.timeZone)
        #expect(!early.correct.contains(.times))
        // No time at all equals an all-day window for the times field.
        let none = InterpretationScorer.score(InterpretationLabel("anything"), actual: InterpretedFields(), now: InterpretationSet.now, timeZone: InterpretationSet.timeZone)
        #expect(none.isExact)
    }
}
