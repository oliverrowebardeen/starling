import Foundation
@testable import StarlingAgent
@testable import StarlingAgentBench
import StarlingCore
import StarlingFakes
import Testing

@Suite struct NegotiationBenchTests {
    @Test func runsEveryWorkloadAndStopsAtAccept() async throws {
        actor Counter { var calls = 0; func next() -> Int { calls += 1; return calls } }
        let counter = Counter()
        // Counter once with compliant-looking terms, then accept.
        let model = ScriptedAgentModel(
            usage: TokenUsage(inputTokens: 300, outputTokens: 20),
            latency: .milliseconds(5),
            onInterpret: { _, _ in .empty },
            onDecide: { context in
                await counter.next() % 2 == 1 ? .counter(context.proposal.terms) : .accept
            }
        )
        let bench = NegotiationBench(model: model, tokensAreEstimates: false, timeZone: AgentFixtures.utc, now: AgentFixtures.now)
        let report = try await bench.run()

        let decide = report.measurements.filter { $0.task == .decide }
        #expect(decide.count == 3 * 2)
        #expect(decide.map(\.outcome) == ["counter", "accept", "counter", "accept", "counter", "accept"])
        #expect(report.measurements.filter { $0.task == .interpret }.count == BenchScenarios.utterances.count)
        #expect(report.measurements.filter { $0.task == .match }.count == 3)
        #expect(report.worstCaseTokens == 320)
        #expect(report.fitsFloorBudget == true)
    }

    @Test func recordsErrorsAndViolations() async throws {
        let model = ScriptedAgentModel(onDecide: { _ in .accept })
        let bench = NegotiationBench(model: model, tokensAreEstimates: true, timeZone: AgentFixtures.utc, now: AgentFixtures.now)
        let report = try await bench.run()
        // The openings deliberately break the other side's limits.
        #expect(report.summaries.first { $0.task == .decide }?.violations == 3)
        #expect(report.summaries.first { $0.task == .interpret }?.errors == BenchScenarios.utterances.count)
        #expect(report.fitsFloorBudget == nil)
        #expect(report.markdown().contains("**estimated**"))
    }

    /// A context overflow has no token count. It must not disappear from the
    /// verdict and leave the report claiming the run fits.
    @Test func contextOverflowMeansDoesNotFit() async throws {
        let model = ScriptedAgentModel(
            usage: TokenUsage(inputTokens: 300, outputTokens: 20),
            onInterpret: { _, _ in .empty },
            onDecide: { _ in throw AgentModelError.contextWindowExceeded }
        )
        let report = try await NegotiationBench(model: model, tokensAreEstimates: false, timeZone: AgentFixtures.utc, now: AgentFixtures.now).run()
        #expect(report.worstCaseTokens == 320)
        #expect(report.fitsFloorBudget == false)
        #expect(report.markdown().contains("exceeded the context window"))
    }

    @Test func partialMeasurementsCannotClaimAFit() async throws {
        // interpret is unscripted, so those calls fail without token counts.
        let model = ScriptedAgentModel(usage: TokenUsage(inputTokens: 300, outputTokens: 20), onDecide: { _ in .accept })
        let report = try await NegotiationBench(model: model, tokensAreEstimates: false, timeZone: AgentFixtures.utc, now: AgentFixtures.now).run()
        #expect(report.worstCaseTokens == 320)
        #expect(report.fitsFloorBudget == nil)
        #expect(report.markdown().contains("cannot claim a fit"))
    }

    /// Missing measurements block a pass, but must not hide a failure that
    /// the measured calls already prove.
    @Test func provenOverBudgetCallsFailEvenWhenOthersAreUnmeasured() async throws {
        // interpret is unscripted, so those calls fail without token counts.
        let model = ScriptedAgentModel(usage: TokenUsage(inputTokens: 3_000, outputTokens: 10), onDecide: { _ in .accept })
        let report = try await NegotiationBench(model: model, tokensAreEstimates: false, timeZone: AgentFixtures.utc, now: AgentFixtures.now).run()
        #expect(report.unmeasuredCalls > 0)
        #expect(report.fitsFloorBudget == false)
        #expect(report.markdown().contains("Does not fit the ADR 0002 budget"))
    }

    @Test func percentilesUseNearestRank() {
        #expect(BenchReport.percentile([5, 1, 3, 2, 4], 0.5) == 3)
        #expect(BenchReport.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.95) == 10)
        #expect(BenchReport.percentile([Int](), 0.5) == nil)
    }
}

/// Runs the real on-device model. Opt in with STARLING_MODEL_TESTS=1 on a Mac
/// or device with Apple Intelligence enabled.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STARLING_MODEL_TESTS"] == "1"))
struct LiveModelTests {
    @Test(.timeLimit(.minutes(2)))
    func decideReturnsAValidatedMove() async throws {
        let agent = FoundationModelsAgent(timeZone: AgentFixtures.utc)
        let result = try await agent.decide(try AgentFixtures.context())
        #expect(result.latency > .zero)
    }

    /// Scores the labeled set with the real model and prints the report.
    @Test(.timeLimit(.minutes(5)))
    func interpretationSetScores() async throws {
        let report = await InterpretationEval(model: FoundationModelsAgent(timeZone: InterpretationSet.timeZone)).run()
        print(report.markdown(title: "Interpretation accuracy (live)"))
        #expect(report.errors == 0)
    }

    @Test(.timeLimit(.minutes(2)))
    func matchFindsTheObviousPair() async throws {
        let agent = FoundationModelsAgent()
        let result = try await agent.match(wanted: [try Keyword("noodles")], offered: [try Keyword("ramen"), try Keyword("bowling")])
        #expect(result.value.contains { $0.offered.value == "ramen" })
    }
}
