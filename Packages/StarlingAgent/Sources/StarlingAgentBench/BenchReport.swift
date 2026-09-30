import Foundation
import StarlingCore

public struct TaskSummary: Codable, Hashable, Sendable {
    public let task: Measurement.Task
    public let calls: Int
    public let errors: Int
    public let violations: Int
    public let inputTokensP50: Int?
    public let inputTokensMax: Int?
    public let outputTokensP50: Int?
    public let outputTokensMax: Int?
    public let totalTokensMax: Int?
    public let latencyP50Milliseconds: Double?
    public let latencyP95Milliseconds: Double?
    public let latencyMaxMilliseconds: Double?
}

public struct BenchReport: Codable, Sendable {
    /// Rounds should stay under this share of the context (ADR 0002).
    public static let roundBudgetShare = 0.5
    public static let floorContextSize = 4096

    public let startedAt: Date
    public let device: String
    public let osVersion: String
    public let model: ModelDescriptor
    public let modelVariant: String?
    public let tokensAreEstimates: Bool
    public let measurements: [Measurement]

    public var summaries: [TaskSummary] {
        Measurement.Task.allCases.compactMap { task in
            let calls = measurements.filter { $0.task == task }
            guard !calls.isEmpty else { return nil }
            let ok = calls.filter { !$0.isError }
            return TaskSummary(
                task: task,
                calls: calls.count,
                errors: calls.count - ok.count,
                violations: calls.filter { !$0.limitViolations.isEmpty }.count,
                inputTokensP50: Self.percentile(ok.compactMap(\.inputTokens), 0.5),
                inputTokensMax: ok.compactMap(\.inputTokens).max(),
                outputTokensP50: Self.percentile(ok.compactMap(\.outputTokens), 0.5),
                outputTokensMax: ok.compactMap(\.outputTokens).max(),
                totalTokensMax: ok.compactMap(\.totalTokens).max(),
                latencyP50Milliseconds: Self.percentile(ok.map(\.latencyMilliseconds), 0.5),
                latencyP95Milliseconds: Self.percentile(ok.map(\.latencyMilliseconds), 0.95),
                latencyMaxMilliseconds: ok.map(\.latencyMilliseconds).max()
            )
        }
    }

    /// Largest single call, in tokens.
    public var worstCaseTokens: Int? { measurements.compactMap(\.totalTokens).max() }

    /// Whether every call fits in half of a 4096-token window (ADR 0002).
    public var fitsFloorBudget: Bool? {
        worstCaseTokens.map { Double($0) <= Double(Self.floorContextSize) * Self.roundBudgetShare }
    }

    /// Nearest-rank percentile.
    static func percentile<T: Comparable>(_ values: [T], _ p: Double) -> T? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    public func markdown() -> String {
        func number<T>(_ value: T?) -> String { value.map { "\($0)" } ?? "n/a" }
        func ms(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "n/a" }

        var lines = [
            "## Model bench: \(device), \(osVersion)",
            "",
            "- Model: `\(model.identifier)`\(modelVariant.map { " (\($0))" } ?? ""), context \(model.contextSize) tokens",
            "- Tokens: \(tokensAreEstimates ? "**estimated** (characters / 3.5; this SDK cannot count)" : "counted with `tokenCount(for:)`; input includes the schema, so it is an upper bound")",
            "- Run: \(ISO8601DateFormatter().string(from: startedAt))",
            "",
            "| Task | Calls | Errors | Limit violations | Input p50 / max | Output p50 / max | Total max | Latency p50 / p95 / max (ms) |",
            "|------|------:|-------:|-----------------:|----------------:|-----------------:|----------:|-----------------------------:|",
        ]
        for summary in summaries {
            lines.append("| \(summary.task.rawValue) | \(summary.calls) | \(summary.errors) | \(summary.violations) | \(number(summary.inputTokensP50)) / \(number(summary.inputTokensMax)) | \(number(summary.outputTokensP50)) / \(number(summary.outputTokensMax)) | \(number(summary.totalTokensMax)) | \(ms(summary.latencyP50Milliseconds)) / \(ms(summary.latencyP95Milliseconds)) / \(ms(summary.latencyMaxMilliseconds)) |")
        }

        lines.append("")
        if let worst = worstCaseTokens, let fits = fitsFloorBudget {
            let share = Double(worst) / Double(Self.floorContextSize) * 100
            lines.append("**Worst single call: \(worst) tokens, \(String(format: "%.0f", share))% of a 4096-token window. \(fits ? "Fits" : "Does not fit") the ADR 0002 budget of \(Int(Double(Self.floorContextSize) * Self.roundBudgetShare)) tokens per round.**")
        } else {
            lines.append("**No token counts available.**")
        }

        lines += ["", "| Scenario | Round | Outcome | Tokens in / out | Latency (ms) | Violations | Output |", "|---|---:|---|---:|---:|---|---|"]
        for m in measurements {
            lines.append("| \(m.task.rawValue): \(m.scenario) | \(m.round) | \(m.outcome) | \(number(m.inputTokens)) / \(number(m.outputTokens)) | \(ms(m.latencyMilliseconds)) | \(m.limitViolations.joined(separator: "; ")) | \(m.detail) |")
        }
        return lines.joined(separator: "\n")
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
