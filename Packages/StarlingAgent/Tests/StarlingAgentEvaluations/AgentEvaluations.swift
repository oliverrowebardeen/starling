// Evaluations framework suites for the agent's model tasks. They need the
// iOS 27 or macOS 27 runtime: on a macOS 26 host they compile but are
// skipped. CI's xcode-27 runner (macOS 27) runs them against a scripted
// oracle, which checks the wiring. STARLING_MODEL_TESTS=1 on a macOS 27
// host with Apple Intelligence runs them against the real model.
#if canImport(Evaluations)
import Evaluations
import Foundation
import StarlingAgent
import StarlingAgentBench
import StarlingCore
import StarlingFakes
import Testing

// MARK: - Interpretation

@available(iOS 27.0, macOS 27.0, *)
struct InterpretationSample: SampleProtocol {
    let label: InterpretationLabel
    var input: String { label.text }
    /// The canonical answer, for reports. Scoring uses `label`, which
    /// allows the tolerances a single expected value cannot express.
    var expected: InterpretedFields? {
        (try? label.rules(context: InterpretationSet.context)).map {
            InterpretedFields($0, now: InterpretationSet.now, timeZone: InterpretationSet.timeZone)
        }
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct InterpretationEvaluation: Evaluation {
    let model: any AgentModel
    let labels: [InterpretationLabel]

    var dataset: ArrayLoader<InterpretationSample> { ArrayLoader(samples: labels.map(InterpretationSample.init)) }

    func subject(from sample: InterpretationSample) async throws -> ModelSubject<InterpretedFields> {
        let result = try await model.interpret(try OwnerUtterance(sample.label.text), context: InterpretationSet.context)
        return ModelSubject(value: InterpretedFields(result.value, now: InterpretationSet.now, timeZone: InterpretationSet.timeZone))
    }

    var evaluators: Evaluators {
        Self.field(.days)
        Self.field(.times)
        Self.field(.wants)
        Self.field(.avoids)
        Self.field(.budget)
        Self.field(.neverShare)
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        for field in InterpretationField.allCases { aggregator.computeMean(of: Self.metric(field)) }
    }

    static func metric(_ field: InterpretationField) -> Metric { Metric(field.rawValue) }

    static func field(_ field: InterpretationField) -> Evaluator<InterpretationSample> {
        Evaluator { sample, subject in
            let score = InterpretationScorer.score(sample.label, actual: subject.value, now: InterpretationSet.now, timeZone: InterpretationSet.timeZone)
            return score.correct.contains(field) ? metric(field).passing() : metric(field).failing()
        }
    }
}

// MARK: - Matching

@available(iOS 27.0, macOS 27.0, *)
struct MatchSample: SampleProtocol {
    let label: MatchLabel
    var input: String { "\(label.wanted) vs \(label.offered)" }
    var expected: [String]? {
        label.wanted.compactMap { want in label.satisfies[want]?.first.map { "\(want)=\($0)" } }
    }
}

@available(iOS 27.0, macOS 27.0, *)
struct MatchEvaluation: Evaluation {
    static let noFalseMatch = Metric("no false match")
    static let wantsFound = Metric("wants found")

    let model: any AgentModel

    var dataset: ArrayLoader<MatchSample> { ArrayLoader(samples: MatchSet.labels.map(MatchSample.init)) }

    func subject(from sample: MatchSample) async throws -> ModelSubject<[String]> {
        let result = try await model.match(wanted: try sample.label.wanted.map { try Keyword($0) }, offered: try sample.label.offered.map { try Keyword($0) })
        return ModelSubject(value: result.value.map { "\($0.wanted.value)=\($0.offered.value)" })
    }

    var evaluators: Evaluators {
        // Red-team issue #9: an unrelated offer must not satisfy a want.
        Evaluator<MatchSample> { sample, subject in
            let falseMatches = subject.value.filter { pair in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return !(sample.label.satisfies[parts[0]] ?? []).contains(parts[1])
            }
            return falseMatches.isEmpty ? Self.noFalseMatch.passing() : Self.noFalseMatch.failing(rationale: falseMatches.joined(separator: ", "))
        }
        Evaluator<MatchSample> { sample, subject in
            let satisfiable = sample.label.wanted.filter { !(sample.label.satisfies[$0] ?? []).isEmpty }
            guard !satisfiable.isEmpty else { return Self.wantsFound.ignore(rationale: "negative control") }
            let found = satisfiable.filter { want in
                subject.value.contains { pair in (sample.label.satisfies[want] ?? []).contains { pair == "\(want)=\($0)" } }
            }
            return Self.wantsFound.scoring(Double(found.count) / Double(satisfiable.count))
        }
    }

    func aggregateMetrics(using aggregator: inout MetricsAggregator) {
        aggregator.computeMean(of: Self.noFalseMatch)
        aggregator.computeMean(of: Self.wantsFound)
    }
}

// MARK: - Suites

/// Scripted oracles: they answer every labeled case correctly, so these
/// tests check that the suites are wired to the scorers, not model quality.
enum Oracles {
    static let interpret = ScriptedAgentModel(onInterpret: { utterance, context in
        let labels = InterpretationSet.labels + InterpretationSet.heldOut
        guard let label = labels.first(where: { $0.text == utterance.text }) else { throw AgentModelError.unsupported }
        return try label.rules(context: context)
    })

    static let match = ScriptedAgentModel(onMatch: { wanted, offered in
        guard let label = MatchSet.labels.first(where: { $0.wanted == wanted.map(\.value) && $0.offered == offered.map(\.value) }) else { return [] }
        return try wanted.compactMap { want in
            try label.satisfies[want.value]?.first.map { KeywordMatch(wanted: want, offered: try Keyword($0), strength: .satisfies) }
        }
    })
}

@Suite struct AgentEvaluations {
    static var live: Bool { ProcessInfo.processInfo.environment["STARLING_MODEL_TESTS"] == "1" }

    @available(iOS 27.0, macOS 27.0, *)
    @Test func interpretationSuiteScoresTheOracle() async throws {
        let result = try await InterpretationEvaluation(model: Oracles.interpret, labels: InterpretationSet.labels).run()
        #expect(!result.errors.hasFailures)
        for field in InterpretationField.allCases {
            #expect(result.aggregateValue(.mean(of: InterpretationEvaluation.metric(field))) == 1, "\(field)")
        }
    }

    @available(iOS 27.0, macOS 27.0, *)
    @Test func matchSuiteScoresTheOracle() async throws {
        let result = try await MatchEvaluation(model: Oracles.match).run()
        #expect(!result.errors.hasFailures)
        #expect(result.aggregateValue(.mean(of: MatchEvaluation.noFalseMatch)) == 1)
        #expect(result.aggregateValue(.mean(of: MatchEvaluation.wantsFound)) == 1)
    }

    /// Evaluation.run() logs a sample whose model call threw and leaves it
    /// out of the means, so a mean can pass on the samples that survived.
    /// Every suite here must also check `errors` (Codex re-review of PR #19);
    /// this confirms a failed call shows up there.
    @available(iOS 27.0, macOS 27.0, *)
    @Test func failedInferenceIsReportedNotSkipped() async throws {
        let failing = ScriptedAgentModel(onInterpret: { utterance, context in
            if utterance.text == InterpretationSet.labels[0].text { throw AgentModelError.interrupted }
            return try await Oracles.interpret.onInterpret(utterance, context)
        })
        let result = try await InterpretationEvaluation(model: failing, labels: InterpretationSet.labels).run()
        #expect(result.errors.inferenceFailureCount == 1)
        #expect(result.errors.hasFailures)
    }

    /// Real model. Prints the per-field summary; thresholds sit a little
    /// under the macOS 26.7 numbers in Reports/phase-1-quality.md, so a
    /// regression fails but run-to-run noise does not. A failed model call
    /// fails the test, rather than dropping out of the means.
    @available(iOS 27.0, macOS 27.0, *)
    @Test(.enabled(if: live), .timeLimit(.minutes(10)))
    func interpretationWithTheRealModel() async throws {
        let agent = FoundationModelsAgent(timeZone: InterpretationSet.timeZone)
        let tuning = try await InterpretationEvaluation(model: agent, labels: InterpretationSet.labels).run(info: ["set": "tuning"])
        let heldOut = try await InterpretationEvaluation(model: agent, labels: InterpretationSet.heldOut).run(info: ["set": "held-out"])
        print("Interpretation (tuning):\n\(tuning.groupedSummary)\nInterpretation (held-out):\n\(heldOut.groupedSummary)")
        #expect(!tuning.errors.hasFailures, "tuning: \(tuning.errors)")
        #expect(!heldOut.errors.hasFailures, "held-out: \(heldOut.errors)")
        #expect(tuning.aggregateValue(.mean(of: InterpretationEvaluation.metric(.neverShare))) >= 0.85)
        #expect(tuning.aggregateValue(.mean(of: InterpretationEvaluation.metric(.budget))) >= 0.85)
    }

    @available(iOS 27.0, macOS 27.0, *)
    @Test(.enabled(if: live), .timeLimit(.minutes(10)))
    func matchingWithTheRealModel() async throws {
        let result = try await MatchEvaluation(model: FoundationModelsAgent()).run()
        print("Matching:\n\(result.groupedSummary)")
        #expect(!result.errors.hasFailures, "\(result.errors)")
        #expect(result.aggregateValue(.mean(of: MatchEvaluation.noFalseMatch)) >= 0.7)
    }
}
#endif
