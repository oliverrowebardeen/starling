import Foundation
import StarlingAgent
import StarlingCore

/// What an owner utterance should interpret to, with tolerance where the
/// owner's words are vague ("tonight" can reasonably start at 17 or 19).
public struct InterpretationLabel: Hashable, Sendable, Codable {
    public enum Day: String, Hashable, Sendable, Codable, CaseIterable {
        case today, tomorrow, monday, tuesday, wednesday, thursday, friday, saturday, sunday
    }

    public let text: String
    /// The day the owner named, or nil for no particular day.
    public let day: Day?
    /// Acceptable start hours. `0...0` when the owner gave no start.
    public let from: ClosedRange<Int>
    /// Acceptable end hours. `24...24` when the owner gave no end.
    public let to: ClosedRange<Int>
    /// Each item is one expected activity, with `|` between acceptable spellings.
    public let wants: [String]
    public let avoids: [String]
    public let budget: Int?
    public let neverShare: [IssueKey]

    public init(
        _ text: String,
        day: Day? = nil,
        from: ClosedRange<Int> = 0...0,
        to: ClosedRange<Int> = 24...24,
        wants: [String] = [],
        avoids: [String] = [],
        budget: Int? = nil,
        neverShare: [IssueKey] = []
    ) {
        self.text = text
        self.day = day
        self.from = from
        self.to = to
        self.wants = wants
        self.avoids = avoids
        self.budget = budget
        self.neverShare = neverShare
    }

    /// Days from `now` to the labeled day, the same way interpretation
    /// resolves a weekday: the next such day, today included.
    public func dayOffset(now: Date, timeZone: TimeZone) -> Int? {
        guard let day else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let weekday: Int
        switch day {
        case .today: return 0
        case .tomorrow: return 1
        case .sunday: weekday = 1
        case .monday: weekday = 2
        case .tuesday: weekday = 3
        case .wednesday: weekday = 4
        case .thursday: weekday = 5
        case .friday: weekday = 6
        case .saturday: weekday = 7
        }
        return (weekday - calendar.component(.weekday, from: now) + 7) % 7
    }

    /// The rules a perfect interpretation would produce, taking the lower
    /// bound of each tolerance and the first spelling of each activity. Lets
    /// a scripted model act as an oracle.
    public func rules(context: InterpretationContext) throws -> OwnerRules {
        let hasTime = day != nil || from != 0...0 || to != 24...24
        let raw = RawRules(
            day: dayOffset(now: context.now, timeZone: context.timeZone).map { .relative($0) },
            earliestHour: hasTime ? from.lowerBound : nil,
            latestHour: hasTime ? to.lowerBound : nil,
            wants: wants.map { String($0.split(separator: "|")[0]) },
            avoids: avoids.map { String($0.split(separator: "|")[0]) },
            maxDollars: budget,
            neverShare: neverShare.compactMap { issue in
                switch issue {
                case .place: .location
                case .time: .schedule
                case .budget: .budget
                default: nil
                }
            }
        )
        return try OutputMapping.rules(raw, context: context)
    }
}

/// The scored fields of an `OwnerRules`, flattened so a label can be
/// compared with what the model produced.
public struct InterpretedFields: Hashable, Sendable, Codable {
    /// Days from today, or nil when the rules name no particular day.
    public var dayOffset: Int?
    /// Nil when there is no time constraint at all.
    public var fromHour: Int?
    public var toHour: Int?
    public var wants: [String]
    public var avoids: [String]
    public var maxDollars: Int?
    public var neverShare: [String]

    public init(dayOffset: Int? = nil, fromHour: Int? = nil, toHour: Int? = nil, wants: [String] = [], avoids: [String] = [], maxDollars: Int? = nil, neverShare: [String] = []) {
        self.dayOffset = dayOffset
        self.fromHour = fromHour
        self.toHour = toHour
        self.wants = wants
        self.avoids = avoids
        self.maxDollars = maxDollars
        self.neverShare = neverShare
    }

    public init(_ rules: OwnerRules, now: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.init()
        for constraint in rules.constraints[.time] {
            switch constraint.rule {
            case .within(let slots):
                guard let slot = slots.first else { continue }
                let today = calendar.startOfDay(for: now)
                let day = calendar.startOfDay(for: slot.start)
                dayOffset = calendar.dateComponents([.day], from: today, to: day).day
                fromHour = calendar.component(.hour, from: slot.start)
                let endDay = calendar.startOfDay(for: slot.end)
                toHour = endDay > day && calendar.component(.hour, from: slot.end) == 0 ? 24 : calendar.component(.hour, from: slot.end)
            case .dailyWindow(let from, let to):
                fromHour = from / 60
                toHour = to / 60
            default:
                continue
            }
            break
        }
        for constraint in rules.constraints[.activity] {
            if case .prefers(let liked, let avoided) = constraint.rule {
                wants += liked.map(\.value)
                avoids += avoided.map(\.value)
            }
        }
        for constraint in rules.constraints[.budget] {
            if case .atMost(let amount) = constraint.rule { maxDollars = Int(amount.minorUnits / 100) }
        }
        neverShare = rules.disclosure.filter { $0.action == .never }.map(\.issue.rawValue).sorted()
    }
}

/// One scored field. The six the Phase 1 plan asks for.
public enum InterpretationField: String, Hashable, Sendable, Codable, CaseIterable {
    case days, times, wants, avoids, budget, neverShare = "never-share"
}

/// How one utterance scored.
public struct InterpretationResult: Hashable, Sendable, Codable {
    public let label: InterpretationLabel
    /// Nil when the model call failed.
    public let actual: InterpretedFields?
    public let error: String?
    public let correct: Set<InterpretationField>
    /// Activities the model produced that match nothing the owner asked for.
    public let inventedWants: [String]
    /// Never-share flags the owner did not ask for.
    public let extraNeverShare: [String]
    /// Never-share flags the owner asked for that the model missed. The
    /// privacy-relevant direction: a miss lets data leave unless the owner
    /// catches it in review.
    public let missedNeverShare: [String]
    public let usage: TokenUsage?
    public let latencyMilliseconds: Double

    public var isExact: Bool { correct.count == InterpretationField.allCases.count }
}

public enum InterpretationScorer {
    public static func score(_ label: InterpretationLabel, actual: InterpretedFields, now: Date, timeZone: TimeZone, usage: TokenUsage? = nil, latencyMilliseconds: Double = 0) -> InterpretationResult {
        var correct = Set<InterpretationField>()
        if actual.dayOffset == label.dayOffset(now: now, timeZone: timeZone) { correct.insert(.days) }
        // No time constraint and an all-day window mean the same thing here;
        // the days field tells them apart.
        if label.from.contains(actual.fromHour ?? 0), label.to.contains(actual.toHour ?? 24) { correct.insert(.times) }

        let wants = compare(expected: label.wants, actual: actual.wants)
        if wants.missing.isEmpty, wants.extra.isEmpty { correct.insert(.wants) }
        let avoids = compare(expected: label.avoids, actual: actual.avoids)
        if avoids.missing.isEmpty, avoids.extra.isEmpty { correct.insert(.avoids) }

        if actual.maxDollars == label.budget { correct.insert(.budget) }

        let expectedShare = Set(label.neverShare.map(\.rawValue))
        let actualShare = Set(actual.neverShare)
        if expectedShare == actualShare { correct.insert(.neverShare) }

        return InterpretationResult(
            label: label,
            actual: actual,
            error: nil,
            correct: correct,
            inventedWants: wants.extra,
            extraNeverShare: actualShare.subtracting(expectedShare).sorted(),
            missedNeverShare: expectedShare.subtracting(actualShare).sorted(),
            usage: usage,
            latencyMilliseconds: latencyMilliseconds
        )
    }

    public static func failure(_ label: InterpretationLabel, error: String) -> InterpretationResult {
        InterpretationResult(
            label: label, actual: nil, error: error, correct: [], inventedWants: [], extraNeverShare: [],
            missedNeverShare: label.neverShare.map(\.rawValue).sorted(), usage: nil, latencyMilliseconds: 0
        )
    }

    /// Lenient keyword comparison: "boba run" satisfies "boba", "tacos"
    /// satisfies "taco". Every expected item needs a match, and every actual
    /// keyword must match some expected item (otherwise it was invented).
    static func compare(expected: [String], actual: [String]) -> (missing: [String], extra: [String]) {
        let alternatives = expected.map { $0.split(separator: "|").map(String.init) }
        let missing = zip(expected, alternatives).filter { _, alts in
            !actual.contains { word in alts.contains { same(word, $0) } }
        }.map(\.0)
        let extra = actual.filter { word in !alternatives.joined().contains { same(word, $0) } }
        return (missing, extra)
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let left = words(a), right = words(b)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left.isSubset(of: right) || right.isSubset(of: left)
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map { word in
            word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : String(word)
        })
    }
}

/// Runs the labeled set through any `AgentModel` and scores each field.
public struct InterpretationEval: Sendable {
    public let model: any AgentModel
    public let labels: [InterpretationLabel]
    public let now: Date
    public let timeZone: TimeZone

    public init(model: any AgentModel, labels: [InterpretationLabel] = InterpretationSet.labels, now: Date = InterpretationSet.now, timeZone: TimeZone = InterpretationSet.timeZone) {
        self.model = model
        self.labels = labels
        self.now = now
        self.timeZone = timeZone
    }

    public func run(progress: @Sendable (InterpretationResult) -> Void = { _ in }) async -> InterpretationReport {
        var results: [InterpretationResult] = []
        let context = InterpretationContext(now: now, timeZone: timeZone, issues: [.time, .activity, .budget])
        for label in labels {
            let result: InterpretationResult
            do {
                let output = try await model.interpret(try OwnerUtterance(label.text), context: context)
                let (seconds, attoseconds) = output.latency.components
                result = InterpretationScorer.score(
                    label,
                    actual: InterpretedFields(output.value, now: now, timeZone: timeZone),
                    now: now,
                    timeZone: timeZone,
                    usage: output.usage,
                    latencyMilliseconds: Double(seconds) * 1000 + Double(attoseconds) / 1e15
                )
            } catch {
                result = InterpretationScorer.failure(label, error: "\(error)")
            }
            results.append(result)
            progress(result)
        }
        return InterpretationReport(model: model.descriptor, results: results)
    }
}

public struct InterpretationReport: Sendable, Codable {
    public let model: ModelDescriptor
    public let results: [InterpretationResult]

    public func correct(_ field: InterpretationField) -> Int { results.filter { $0.correct.contains(field) }.count }
    public func accuracy(_ field: InterpretationField) -> Double {
        results.isEmpty ? 0 : Double(correct(field)) / Double(results.count)
    }
    public var exact: Int { results.filter(\.isExact).count }
    public var errors: Int { results.filter { $0.error != nil }.count }
    public var inventedWants: Int { results.map(\.inventedWants.count).reduce(0, +) }
    public var extraNeverShare: Int { results.map(\.extraNeverShare.count).reduce(0, +) }
    public var missedNeverShare: Int { results.map(\.missedNeverShare.count).reduce(0, +) }
    /// A budget the owner named that the model left out.
    public var droppedBudgets: Int { results.filter { $0.label.budget != nil && $0.actual != nil && $0.actual?.maxDollars == nil }.count }
    /// A budget the model produced when the owner named none.
    public var inventedBudgets: Int { results.filter { $0.label.budget == nil && $0.actual?.maxDollars != nil }.count }
    public var worstTokens: Int? { results.compactMap(\.usage?.total).max() }

    public func markdown(title: String = "Interpretation accuracy") -> String {
        func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
        var lines = [
            "## \(title)",
            "",
            "- Model: `\(model.identifier)`, \(results.count) labeled utterances, \(errors) failed calls",
            "- Worst call: \(worstTokens.map { "\($0) tokens" } ?? "n/a")",
            "",
            "| Field | Correct | Accuracy |",
            "|-------|--------:|---------:|",
        ]
        for field in InterpretationField.allCases {
            lines.append("| \(field.rawValue) | \(correct(field)) / \(results.count) | \(percent(accuracy(field))) |")
        }
        lines.append("| **all six** | \(exact) / \(results.count) | \(percent(results.isEmpty ? 0 : Double(exact) / Double(results.count))) |")
        lines += [
            "",
            "| Failure mode | Count |",
            "|--------------|------:|",
            "| Never-share flags over-triggered | \(extraNeverShare) |",
            "| Never-share flags missed | \(missedNeverShare) |",
            "| Invented activities | \(inventedWants) |",
            "| Dropped budgets | \(droppedBudgets) |",
            "| Invented budgets | \(inventedBudgets) |",
            "",
            "| # | Utterance | Wrong fields | Got |",
            "|--:|-----------|--------------|-----|",
        ]
        for (index, result) in results.enumerated() where !result.isExact {
            let wrong = InterpretationField.allCases.filter { !result.correct.contains($0) }.map(\.rawValue).joined(separator: ", ")
            lines.append("| \(index + 1) | \(result.label.text) | \(wrong) | \(result.error ?? result.actual.map(Self.describe) ?? "") |")
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ fields: InterpretedFields) -> String {
        var parts: [String] = []
        if let day = fields.dayOffset { parts.append("day +\(day)") }
        if fields.fromHour != nil || fields.toHour != nil { parts.append("\(fields.fromHour ?? 0)-\(fields.toHour ?? 24)") }
        if !fields.wants.isEmpty { parts.append("wants " + fields.wants.joined(separator: ", ")) }
        if !fields.avoids.isEmpty { parts.append("avoids " + fields.avoids.joined(separator: ", ")) }
        if let dollars = fields.maxDollars { parts.append("$\(dollars)") }
        if !fields.neverShare.isEmpty { parts.append("never " + fields.neverShare.joined(separator: ", ")) }
        return parts.isEmpty ? "(nothing)" : parts.joined(separator: "; ")
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
