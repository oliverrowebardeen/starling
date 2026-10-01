import Foundation
import StarlingCore

// Scoring for routing and chips (ADR 0016), the ADR 0160 way: plain code
// over labeled sets, so a prompt or schema change is measured before and
// after on the same data, with any SkillModel (scripted in CI, the real
// model with agent-bench or STARLING_MODEL_TESTS=1).

func milliseconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) * 1000 + Double(attoseconds) / 1e15
}

// MARK: - Routing

public struct RoutingResult: Hashable, Sendable, Codable {
    public let label: RoutingLabel
    /// The skill chosen, "none", or nil when the call failed.
    public let actual: String?
    public let error: String?
    public let usage: TokenUsage?
    public let latencyMilliseconds: Double

    public var isCorrect: Bool { error == nil && actual == (label.skill ?? "none") }
}

public struct RoutingEval: Sendable {
    public let model: any SkillModel
    public let skills: [SkillDescriptor]
    public let labels: [RoutingLabel]

    public init(model: any SkillModel, skills: [SkillDescriptor], labels: [RoutingLabel] = RoutingSet.labels) {
        self.model = model
        self.skills = skills
        self.labels = labels
    }

    public func run(progress: @Sendable (RoutingResult) -> Void = { _ in }) async -> RoutingReport {
        var results: [RoutingResult] = []
        for label in labels {
            let result: RoutingResult
            do {
                let output = try await model.route(label.text, among: skills)
                result = RoutingResult(label: label, actual: output.value?.rawValue ?? "none", error: nil, usage: output.usage, latencyMilliseconds: milliseconds(output.latency))
            } catch {
                result = RoutingResult(label: label, actual: nil, error: "\(error)", usage: nil, latencyMilliseconds: 0)
            }
            results.append(result)
            progress(result)
        }
        return RoutingReport(model: model.descriptor, results: results)
    }
}

public struct RoutingReport: Sendable, Codable {
    public let model: ModelDescriptor
    public let results: [RoutingResult]

    public var correct: Int { results.filter(\.isCorrect).count }
    public var accuracy: Double { results.isEmpty ? 0 : Double(correct) / Double(results.count) }
    public var errors: Int { results.filter { $0.error != nil }.count }
    /// A request for a skill routed to none: New falls back to the tiles.
    public var missedRequests: Int { results.filter { $0.label.skill != nil && $0.actual == "none" }.count }
    /// Not a request, routed to a skill anyway: the owner sees chips to dismiss.
    public var falseRoutes: Int { results.filter { $0.label.skill == nil && $0.actual != nil && $0.actual != "none" }.count }
    public var worstTokens: Int? { results.compactMap(\.usage?.total).max() }
    public var medianLatency: Double? {
        let sorted = results.map(\.latencyMilliseconds).filter { $0 > 0 }.sorted()
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }

    /// Correct routes per expected skill, "none" included.
    public func correct(for skill: String) -> (Int, Int) {
        let rows = results.filter { ($0.label.skill ?? "none") == skill }
        return (rows.filter(\.isCorrect).count, rows.count)
    }

    public func markdown(title: String = "Routing accuracy") -> String {
        var lines = [
            "## \(title)",
            "",
            "- Model: `\(model.identifier)`, \(results.count) labeled utterances, \(errors) failed calls",
            "- Worst call: \(worstTokens.map { "\($0) tokens" } ?? "n/a"); median latency \(medianLatency.map { String(format: "%.0f ms", $0) } ?? "n/a")",
            "",
            "| Expected | Correct |",
            "|----------|--------:|",
        ]
        for skill in ["down_for", "find_a_time", "pick_a_place", "none"] {
            let (right, total) = correct(for: skill)
            if total > 0 { lines.append("| \(skill) | \(right) / \(total) |") }
        }
        lines.append(String(format: "| **all** | %d / %d (%.0f%%) |", correct, results.count, accuracy * 100))
        lines += ["", "- Requests routed to none: \(missedRequests)", "- Non-requests routed to a skill: \(falseRoutes)", ""]
        let misses = results.enumerated().filter { !$0.element.isCorrect }
        if !misses.isEmpty {
            lines += ["| # | Utterance | Expected | Got |", "|--:|-----------|----------|-----|"]
            for (index, result) in misses {
                lines.append("| \(index + 1) | \(result.label.text) | \(result.label.skill ?? "none") | \(result.error ?? result.actual ?? "") |")
            }
        }
        return lines.joined(separator: "\n")
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

// MARK: - Chips

public enum ChipField: String, Hashable, Sendable, Codable, CaseIterable {
    case days, times, wants, avoids, budget, place, audience, names, mode
}

public struct ChipResult: Hashable, Sendable, Codable {
    public let label: ChipLabel
    public let actual: InterpretedFields?
    public let place: [String]
    public let audience: String?
    public let names: [String]
    public let mode: String?
    public let error: String?
    public let correct: Set<ChipField>
    public let inventedWants: [String]
    public let usage: TokenUsage?
    public let latencyMilliseconds: Double

    public var isExact: Bool { correct.count == ChipField.allCases.count }
}

public enum ChipScorer {
    public static func score(_ label: ChipLabel, parsed: ParsedIntent, now: Date, timeZone: TimeZone, usage: TokenUsage? = nil, latencyMilliseconds: Double = 0) -> ChipResult {
        let fields = InterpretedFields(OwnerRules(constraints: parsed.constraints), now: now, timeZone: timeZone)
        let base = InterpretationScorer.score(label.fields, actual: fields, now: now, timeZone: timeZone)
        var correct = Set<ChipField>()
        let mapping: [(InterpretationField, ChipField)] = [(.days, .days), (.times, .times), (.wants, .wants), (.avoids, .avoids), (.budget, .budget)]
        for (from, to) in mapping where base.correct.contains(from) { correct.insert(to) }

        let place = parsed.constraints[.place].flatMap { constraint -> [String] in
            if case .prefers(let liked, _) = constraint.rule { return liked.map(\.value) }
            return []
        }
        let (missing, extra) = InterpretationScorer.compare(expected: label.place, actual: place)
        if missing.isEmpty, extra.isEmpty { correct.insert(.place) }

        let audience: String? = switch parsed.audience {
        case .allFriends?: "everyone"
        case .closeFriends?: "close"
        case .everyoneExcept?: "except"
        case .group?: "group"
        case .picked?, nil: nil
        }
        if audience == label.audience { correct.insert(.audience) }
        let mode: String? = switch parsed.mode {
        case .askQuietly?: "quietly"
        case .invite?: "invite"
        case nil: nil
        }
        if mode == label.mode { correct.insert(.mode) }
        if parsed.mentionedNames.map({ $0.lowercased() }) == label.names.map({ $0.lowercased() }) { correct.insert(.names) }

        return ChipResult(
            label: label, actual: fields, place: place, audience: audience, names: parsed.mentionedNames, mode: mode, error: nil,
            correct: correct, inventedWants: base.inventedWants, usage: usage, latencyMilliseconds: latencyMilliseconds
        )
    }

    public static func failure(_ label: ChipLabel, error: String) -> ChipResult {
        ChipResult(label: label, actual: nil, place: [], audience: nil, names: [], mode: nil, error: error, correct: [], inventedWants: [], usage: nil, latencyMilliseconds: 0)
    }
}

public struct ChipEval: Sendable {
    public let model: any SkillModel
    public let skill: SkillDescriptor
    public let labels: [ChipLabel]
    public let now: Date
    public let timeZone: TimeZone

    public init(model: any SkillModel, skill: SkillDescriptor, labels: [ChipLabel] = ChipSet.labels, now: Date = InterpretationSet.now, timeZone: TimeZone = InterpretationSet.timeZone) {
        self.model = model
        self.skill = skill
        self.labels = labels
        self.now = now
        self.timeZone = timeZone
    }

    public func run(progress: @Sendable (ChipResult) -> Void = { _ in }) async -> ChipReport {
        var results: [ChipResult] = []
        for label in labels {
            let result: ChipResult
            do {
                let output = try await model.intent(from: label.text, for: skill, now: now, timeZone: timeZone)
                result = ChipScorer.score(label, parsed: output.value, now: now, timeZone: timeZone, usage: output.usage, latencyMilliseconds: milliseconds(output.latency))
            } catch {
                result = ChipScorer.failure(label, error: "\(error)")
            }
            results.append(result)
            progress(result)
        }
        return ChipReport(model: model.descriptor, results: results)
    }
}

public struct ChipReport: Sendable, Codable {
    public let model: ModelDescriptor
    public let results: [ChipResult]

    public func correct(_ field: ChipField) -> Int { results.filter { $0.correct.contains(field) }.count }
    public var exact: Int { results.filter(\.isExact).count }
    public var errors: Int { results.filter { $0.error != nil }.count }
    public var inventedWants: Int { results.map(\.inventedWants.count).reduce(0, +) }
    public var worstTokens: Int? { results.compactMap(\.usage?.total).max() }

    public func markdown(title: String = "Chip accuracy") -> String {
        func percent(_ count: Int) -> String { results.isEmpty ? "0%" : String(format: "%.0f%%", Double(count) / Double(results.count) * 100) }
        var lines = [
            "## \(title)",
            "",
            "- Model: `\(model.identifier)`, \(results.count) labeled utterances, \(errors) failed calls, \(inventedWants) invented activities",
            "- Worst call: \(worstTokens.map { "\($0) tokens" } ?? "n/a")",
            "",
            "| Chip | Correct | Accuracy |",
            "|------|--------:|---------:|",
        ]
        for field in ChipField.allCases {
            lines.append("| \(field.rawValue) | \(correct(field)) / \(results.count) | \(percent(correct(field))) |")
        }
        lines.append("| **all chips** | \(exact) / \(results.count) | \(percent(exact)) |")
        let misses = results.enumerated().filter { !$0.element.isExact }
        if !misses.isEmpty {
            lines += ["", "| # | Utterance | Wrong chips | Got |", "|--:|-----------|-------------|-----|"]
            for (index, result) in misses {
                let wrong = ChipField.allCases.filter { !result.correct.contains($0) }.map(\.rawValue).joined(separator: ", ")
                var got = result.actual.map(InterpretationReport.describe) ?? ""
                if !result.place.isEmpty { got += "; place " + result.place.joined(separator: ", ") }
                if let audience = result.audience { got += "; ask \(audience)" }
                if !result.names.isEmpty { got += "; with " + result.names.joined(separator: ", ") }
                if let mode = result.mode { got += "; mode \(mode)" }
                lines.append("| \(index + 1) | \(result.label.text) | \(wrong) | \(result.error ?? got) |")
            }
        }
        return lines.joined(separator: "\n")
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
