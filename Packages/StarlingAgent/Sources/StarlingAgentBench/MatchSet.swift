import Foundation
import StarlingCore

/// Wants and offers labeled with which offers satisfy each want.
///
/// Negative controls (a want no offer satisfies) come from red-team issue
/// #9: `match(wanted: [food], offered: [movie])` returned an equivalent
/// match in 24 of 24 greedy trials.
public struct MatchLabel: Hashable, Sendable, Codable {
    public let name: String
    public let wanted: [String]
    public let offered: [String]
    /// For each want, the offers that satisfy it. A want with no entry
    /// is a negative control: every pairing with it is a false match.
    public let satisfies: [String: [String]]

    public init(_ name: String, wanted: [String], offered: [String], satisfies: [String: [String]] = [:]) {
        self.name = name
        self.wanted = wanted
        self.offered = offered
        self.satisfies = satisfies
    }

    public var isNegativeControl: Bool { satisfies.values.allSatisfy(\.isEmpty) }
}

public enum MatchSet {
    public static let labels: [MatchLabel] = [
        // Negative controls: nothing offered satisfies the want.
        .init("food-vs-movie", wanted: ["food"], offered: ["movie"]),
        .init("food-vs-bowling", wanted: ["food"], offered: ["bowling"]),
        .init("coffee-vs-karaoke", wanted: ["coffee"], offered: ["karaoke"]),
        .init("hike-vs-pizza", wanted: ["hike"], offered: ["pizza"]),
        .init("study-vs-bar", wanted: ["study"], offered: ["bar"]),
        .init("music-vs-sushi", wanted: ["music"], offered: ["sushi"]),
        .init("movie-vs-tacos", wanted: ["movie"], offered: ["tacos"]),
        .init("sushi-vs-pizza", wanted: ["sushi"], offered: ["pizza"]),
        .init("ramen-vs-sushi", wanted: ["ramen"], offered: ["sushi"]),
        .init("dessert-vs-library", wanted: ["dessert"], offered: ["library"]),
        .init("games-vs-ramen", wanted: ["games"], offered: ["ramen"]),
        .init("boba-vs-hiking", wanted: ["boba"], offered: ["hiking"]),
        .init("outdoors-vs-lists", wanted: ["outdoors"], offered: ["movie", "karaoke", "arcade", "library"]),
        .init("food-vs-lists", wanted: ["food"], offered: ["movie", "bowling", "concert", "hike"]),

        // Positives, one per want.
        .init("food-vs-boba", wanted: ["food"], offered: ["boba run"], satisfies: ["food": ["boba run"]]),
        .init("noodles-vs-ramen", wanted: ["noodles"], offered: ["ramen"], satisfies: ["noodles": ["ramen"]]),
        .init("boba-vs-bubble-tea", wanted: ["boba"], offered: ["bubble tea"], satisfies: ["boba": ["bubble tea"]]),
        .init("movie-vs-film", wanted: ["movie"], offered: ["film"], satisfies: ["movie": ["film"]]),
        .init("exercise-vs-basketball", wanted: ["exercise"], offered: ["basketball"], satisfies: ["exercise": ["basketball"]]),
        .init("dessert-vs-ice-cream", wanted: ["dessert"], offered: ["ice cream"], satisfies: ["dessert": ["ice cream"]]),

        // Mixed lists: some wants match, some do not, with distractors.
        .init("food-among-distractors", wanted: ["food"], offered: ["movie", "boba run"], satisfies: ["food": ["boba run"]]),
        .init("group-menu", wanted: ["noodles", "something sweet", "cheap eats"], offered: ["ramen", "boba", "tacos", "karaoke", "pho", "ice cream"], satisfies: [
            "noodles": ["ramen", "pho"],
            "something sweet": ["boba", "ice cream"],
            "cheap eats": ["tacos", "pho", "ramen"],
        ]),
        .init("max-lists", wanted: ["food", "outdoors", "music", "games", "coffee", "study"], offered: ["boba run", "hike", "concert", "board games", "cafe", "library", "tacos", "beach", "karaoke", "arcade"], satisfies: [
            "food": ["boba run", "tacos"],
            "outdoors": ["hike", "beach"],
            "music": ["concert", "karaoke"],
            "games": ["board games", "arcade"],
            "coffee": ["cafe"],
            "study": ["library"],
        ]),
        .init("half-match", wanted: ["coffee", "bowling"], offered: ["cafe", "movie", "sushi"], satisfies: ["coffee": ["cafe"]]),
        .init("no-overlap-lists", wanted: ["hike", "study", "coffee"], offered: ["karaoke", "pizza", "movie"]),
    ]
}

/// How one labeled case scored.
public struct MatchResult: Hashable, Sendable, Codable {
    public let label: MatchLabel
    /// "want=offer" for every returned pair; nil when the call failed.
    public let pairs: [String]?
    public let error: String?
    /// Returned pairs whose offer does not satisfy the want.
    public let falseMatches: [String]
    /// Wants with a satisfying offer for which the model returned none of them.
    public let missedWants: [String]
    public let usage: TokenUsage?

    public var isCorrect: Bool { error == nil && falseMatches.isEmpty && missedWants.isEmpty }
}

public struct MatchEval: Sendable {
    public let model: any AgentModel
    public let labels: [MatchLabel]

    public init(model: any AgentModel, labels: [MatchLabel] = MatchSet.labels) {
        self.model = model
        self.labels = labels
    }

    public func run(progress: @Sendable (MatchResult) -> Void = { _ in }) async -> MatchReport {
        var results: [MatchResult] = []
        for label in labels {
            let result: MatchResult
            do {
                let wanted = try label.wanted.map { try Keyword($0) }
                let offered = try label.offered.map { try Keyword($0) }
                let output = try await model.match(wanted: wanted, offered: offered)
                result = Self.score(label, matches: output.value, usage: output.usage)
            } catch {
                result = MatchResult(label: label, pairs: nil, error: "\(error)", falseMatches: [], missedWants: label.wanted.filter { !(label.satisfies[$0] ?? []).isEmpty }, usage: nil)
            }
            results.append(result)
            progress(result)
        }
        return MatchReport(model: model.descriptor, results: results)
    }

    public static func score(_ label: MatchLabel, matches: [KeywordMatch], usage: TokenUsage? = nil) -> MatchResult {
        let pairs = matches.map { "\($0.wanted.value)=\($0.offered.value)" }
        let falseMatches = matches.filter { !(label.satisfies[$0.wanted.value] ?? []).contains($0.offered.value) }
            .map { "\($0.wanted.value)=\($0.offered.value)" }
        let missed = label.wanted.filter { want in
            let good = label.satisfies[want] ?? []
            return !good.isEmpty && !matches.contains { $0.wanted.value == want && good.contains($0.offered.value) }
        }
        return MatchResult(label: label, pairs: pairs, error: nil, falseMatches: falseMatches, missedWants: missed, usage: usage)
    }
}

public struct MatchReport: Sendable, Codable {
    public let model: ModelDescriptor
    public let results: [MatchResult]

    /// Negative-control cases (no offer satisfies any want) that got at
    /// least one match anyway. The issue #9 measure.
    public var negativeControls: Int { results.filter(\.label.isNegativeControl).count }
    public var negativeControlsMatched: Int { results.filter { $0.label.isNegativeControl && !$0.falseMatches.isEmpty }.count }
    public var falseMatches: Int { results.map(\.falseMatches.count).reduce(0, +) }
    public var positiveWants: Int { results.map { r in r.label.wanted.filter { !(r.label.satisfies[$0] ?? []).isEmpty }.count }.reduce(0, +) }
    public var missedWants: Int { results.map(\.missedWants.count).reduce(0, +) }
    public var correct: Int { results.filter(\.isCorrect).count }
    public var errors: Int { results.filter { $0.error != nil }.count }
    public var worstTokens: Int? { results.compactMap(\.usage?.total).max() }

    public func markdown(title: String = "Match accuracy") -> String {
        func percent(_ n: Int, _ d: Int) -> String { d == 0 ? "n/a" : String(format: "%.0f%%", Double(n) / Double(d) * 100) }
        var lines = [
            "## \(title)",
            "",
            "- Model: `\(model.identifier)`, \(results.count) labeled cases, \(errors) failed calls",
            "- Worst call: \(worstTokens.map { "\($0) tokens" } ?? "n/a")",
            "",
            "| Measure | Count | Rate |",
            "|---------|------:|-----:|",
            "| Negative controls with a false match | \(negativeControlsMatched) / \(negativeControls) | \(percent(negativeControlsMatched, negativeControls)) |",
            "| False pairs returned (all cases) | \(falseMatches) | |",
            "| Satisfiable wants found | \(positiveWants - missedWants) / \(positiveWants) | \(percent(positiveWants - missedWants, positiveWants)) |",
            "| Cases fully correct | \(correct) / \(results.count) | \(percent(correct, results.count)) |",
            "",
            "| Case | False matches | Missed wants | Got |",
            "|------|---------------|--------------|-----|",
        ]
        for result in results where !result.isCorrect {
            lines.append("| \(result.label.name) | \(result.falseMatches.joined(separator: ", ")) | \(result.missedWants.joined(separator: ", ")) | \(result.error ?? result.pairs?.joined(separator: ", ") ?? "") |")
        }
        return lines.joined(separator: "\n")
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
