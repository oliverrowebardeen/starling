import Foundation
import StarlingAgent
import StarlingCore

/// One model call.
public struct Measurement: Codable, Hashable, Sendable {
    public enum Task: String, Codable, Hashable, Sendable, CaseIterable { case decide, interpret, match }

    public let task: Task
    public let scenario: String
    public let round: Int
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let latencyMilliseconds: Double
    /// `accept`, `counter`, `reject`, `ok`, or `error: ...`.
    public let outcome: String
    /// Hard-limit problems in what the model accepted or countered with.
    public let limitViolations: [String]
    /// What the model produced, briefly, for eyeballing quality.
    public let detail: String

    public var totalTokens: Int? {
        guard let inputTokens, let outputTokens else { return nil }
        return inputTokens + outputTokens
    }
    public var isError: Bool { outcome.hasPrefix("error") }
}

/// Runs the Phase 0 workloads against any `AgentModel` and records tokens,
/// latency, and limit violations per call.
public struct NegotiationBench: Sendable {
    public let model: any AgentModel
    public let tokensAreEstimates: Bool
    public let modelVariant: String?
    public let timeZone: TimeZone
    public let now: Date

    public init(model: any AgentModel, tokensAreEstimates: Bool, modelVariant: String? = nil, timeZone: TimeZone = .current, now: Date = Date()) {
        self.model = model
        self.tokensAreEstimates = tokensAreEstimates
        self.modelVariant = modelVariant
        self.timeZone = timeZone
        self.now = now
    }

    /// - Parameter repetitions: How many times to run each workload.
    /// - Parameter progress: Called after every model call.
    public func run(repetitions: Int = 1, progress: @Sendable (Measurement) -> Void = { _ in }) async throws -> BenchReport {
        var measurements: [Measurement] = []
        func record(_ measurement: Measurement) {
            measurements.append(measurement)
            progress(measurement)
        }

        for _ in 0..<repetitions {
            for scenario in try BenchScenarios.decide(now: now, timeZone: timeZone) {
                for measurement in await negotiate(scenario) { record(measurement) }
            }
            for (index, text) in BenchScenarios.utterances.enumerated() {
                record(await interpret(text, name: "utterance-\(index + 1)"))
            }
            for matchCase in try BenchScenarios.matches() {
                record(await match(matchCase))
            }
        }

        return BenchReport(
            startedAt: now,
            device: DeviceInfo.model,
            osVersion: DeviceInfo.osVersion,
            model: model.descriptor,
            modelVariant: modelVariant,
            tokensAreEstimates: tokensAreEstimates,
            measurements: measurements
        )
    }

    func negotiate(_ scenario: DecideScenario) async -> [Measurement] {
        var results: [Measurement] = []
        var history: [NegotiationRound] = [NegotiationRound(actor: .peer, kind: .propose, terms: scenario.opening)]
        var terms = scenario.opening
        var deciderIsB = true

        for round in 0..<BenchScenarios.maxRounds {
            let constraints = deciderIsB ? scenario.b : scenario.a
            guard let proposal = try? Proposal(round: UInt16(round), terms: terms) else { break }
            let context = NegotiationContext(proposal: proposal, constraints: constraints, history: history, now: now)
            do {
                let result = try await model.decide(context)
                let violations: [String]
                let outcome: String
                let detail: String
                switch result.value {
                case .accept:
                    outcome = "accept"
                    violations = HardLimits.violations(of: terms, against: constraints, timeZone: timeZone)
                    detail = Self.describe(terms, timeZone: timeZone)
                case .reject(let reason):
                    outcome = "reject"
                    violations = []
                    detail = reason.rawValue
                case .counter(let counter):
                    outcome = "counter"
                    violations = HardLimits.violations(of: counter, against: constraints, timeZone: timeZone)
                    detail = Self.describe(counter, timeZone: timeZone)
                    terms = counter
                }
                results.append(measurement(.decide, scenario.name, round, result, outcome: outcome, violations: violations, detail: detail))
                guard case .counter = result.value else { break }
                // Record the move from the next decider's point of view.
                history = history.map { NegotiationRound(actor: $0.actor == .me ? .peer : .me, kind: $0.kind, terms: $0.terms) }
                history.append(NegotiationRound(actor: .peer, kind: .counter, terms: terms))
                deciderIsB.toggle()
            } catch {
                results.append(Measurement(task: .decide, scenario: scenario.name, round: round, inputTokens: nil, outputTokens: nil, latencyMilliseconds: 0, outcome: "error: \(error)", limitViolations: [], detail: ""))
                break
            }
        }
        return results
    }

    func interpret(_ text: String, name: String) async -> Measurement {
        do {
            let utterance = try OwnerUtterance(text)
            let context = InterpretationContext(now: now, timeZone: timeZone, issues: [.time, .activity, .budget])
            let result = try await model.interpret(utterance, context: context)
            return measurement(.interpret, name, 0, result, outcome: "ok", violations: [], detail: Self.describe(result.value, timeZone: timeZone))
        } catch {
            return Measurement(task: .interpret, scenario: name, round: 0, inputTokens: nil, outputTokens: nil, latencyMilliseconds: 0, outcome: "error: \(error)", limitViolations: [], detail: "")
        }
    }

    func match(_ matchCase: MatchCase) async -> Measurement {
        do {
            let result = try await model.match(wanted: matchCase.wanted, offered: matchCase.offered)
            let pairs = result.value.map { "\($0.wanted)=\($0.offered)\($0.strength == .equivalent ? "" : "~")" }
            return measurement(.match, matchCase.name, 0, result, outcome: "ok", violations: [], detail: pairs.joined(separator: ", "))
        } catch {
            return Measurement(task: .match, scenario: matchCase.name, round: 0, inputTokens: nil, outputTokens: nil, latencyMilliseconds: 0, outcome: "error: \(error)", limitViolations: [], detail: "")
        }
    }

    static func describe(_ terms: Terms, timeZone: TimeZone) -> String {
        terms.values.keys.sorted().map { "\($0) \(PromptRenderer.describe(terms.values[$0]!, timeZone: timeZone))" }.joined(separator: "; ")
    }

    static func describe(_ rules: OwnerRules, timeZone: TimeZone) -> String {
        var parts = rules.constraints.constraints.keys.sorted().flatMap { key in
            rules.constraints[key].map { "\(key) \(PromptRenderer.describe($0.rule, timeZone: timeZone))" }
        }
        parts += rules.disclosure.map { "never share \($0.issue)" }
        return parts.joined(separator: "; ")
    }

    private func measurement<T>(_ task: Measurement.Task, _ scenario: String, _ round: Int, _ result: ModelResult<T>, outcome: String, violations: [String], detail: String) -> Measurement {
        let (seconds, attoseconds) = result.latency.components
        return Measurement(
            task: task,
            scenario: scenario,
            round: round,
            inputTokens: result.usage?.inputTokens,
            outputTokens: result.usage?.outputTokens,
            latencyMilliseconds: Double(seconds) * 1000 + Double(attoseconds) / 1e15,
            outcome: outcome,
            limitViolations: violations,
            detail: detail
        )
    }
}

enum DeviceInfo {
    static var model: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
}
