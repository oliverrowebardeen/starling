import Foundation
import StarlingCore

/// An editable copy of `OwnerRules` for the review screen.
///
/// The model's interpretation is only a proposal: the Phase 0 bench measured
/// it inventing activities and sharing flags and dropping budgets
/// (docs/research/model-budget.md). Nothing reaches storage or a
/// `DownService` without passing through a draft the owner has reviewed and
/// `build()`.
///
/// Items are flat structs with a field per rule kind so SwiftUI can bind to
/// them directly; `kind` says which fields matter.
public struct RulesDraft: Hashable, Sendable {
    public enum Origin: Hashable, Sendable {
        /// Produced by interpreting the owner's words; gets review flags.
        case model
        /// Added or written by the owner; never flagged.
        case owner
    }

    public enum Kind: String, Hashable, Sendable, CaseIterable, Identifiable {
        case within, dailyWindow, prefers, atMost, atLeast, mustBe, countBetween
        public var id: String { rawValue }
    }

    public struct Slot: Identifiable, Hashable, Sendable {
        public let id: UUID
        public var start: Date
        public var end: Date

        public init(id: UUID = UUID(), start: Date, end: Date) {
            self.id = id
            self.start = start
            self.end = end
        }
    }

    public struct Item: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let origin: Origin
        public var issue: IssueKey
        public var kind: Kind
        public var strength: Constraint.Strength

        public var slots: [Slot] = []
        public var fromMinute = 9 * 60
        public var toMinute = 22 * 60
        public var liked: [String] = []
        public var avoided: [String] = []
        public var amountMinorUnits: Int64 = 2000
        public var currency = "USD"
        public var flag = true
        public var minCount = 2
        public var maxCount = 4

        init(id: UUID = UUID(), origin: Origin, issue: IssueKey, kind: Kind, strength: Constraint.Strength) {
            self.id = id
            self.origin = origin
            self.issue = issue
            self.kind = kind
            self.strength = strength
        }

        /// `amountMinorUnits` in major units ("15.50" for 1550 cents), for a
        /// currency text field. Rounds to the currency's minor unit.
        public var amount: Decimal {
            get { Decimal(amountMinorUnits) / pow(10, ValueFormatter.fractionDigits(for: currency)) }
            set {
                var scaled = newValue * pow(10, ValueFormatter.fractionDigits(for: currency))
                var rounded = Decimal()
                NSDecimalRound(&rounded, &scaled, 0, .plain)
                amountMinorUnits = NSDecimalNumber(decimal: rounded).int64Value
            }
        }

        /// Comma-separated editing for keyword lists.
        public var likedText: String {
            get { liked.joined(separator: ", ") }
            set { liked = Self.split(newValue) }
        }

        public var avoidedText: String {
            get { avoided.joined(separator: ", ") }
            set { avoided = Self.split(newValue) }
        }

        private static func split(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    public struct Sharing: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let origin: Origin
        public var issue: IssueKey
        public var action: DisclosureRule.Action
    }

    public var items: [Item]
    public var sharing: [Sharing]

    public static let empty = RulesDraft(items: [], sharing: [])

    init(items: [Item], sharing: [Sharing]) {
        self.items = items
        self.sharing = sharing
    }

    public init(_ rules: OwnerRules, origin: Origin = .owner) {
        items = rules.constraints.constraints.keys.sorted().flatMap { issue in
            rules.constraints[issue].map { Self.item(from: $0, issue: issue, origin: origin) }
        }
        // One row per issue: duplicates collapse to the most restrictive
        // action, as the policy engine and RulesMerge treat them.
        var sharing: [Sharing] = []
        for rule in rules.disclosure {
            if let index = sharing.firstIndex(where: { $0.issue == rule.issue }) {
                sharing[index].action = RulesMerge.restrictive(sharing[index].action, rule.action)
            } else {
                sharing.append(Sharing(id: UUID(), origin: origin, issue: rule.issue, action: rule.action))
            }
        }
        self.sharing = sharing
    }

    // MARK: Editing

    public mutating func add(_ kind: Kind, issue: IssueKey, now: Date = Date()) {
        var item = Item(origin: .owner, issue: issue, kind: kind, strength: .hard)
        if kind == .within {
            let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 3600).rounded(.up) * 3600)
            item.slots = [Slot(start: start, end: start.addingTimeInterval(2 * 3600))]
        }
        items.append(item)
    }

    public mutating func addSharing(issue: IssueKey) {
        sharing.append(Sharing(id: UUID(), origin: .owner, issue: issue, action: .askEachTime))
    }

    // MARK: Validation

    public struct Problem: Hashable, Sendable {
        /// The item or sharing rule at fault, or nil for the whole draft.
        public let itemID: UUID?
        public let message: String
    }

    /// Everything that stops `build()`, for showing next to each row.
    public var problems: [Problem] {
        var problems: [Problem] = []
        for item in items {
            do { _ = try Self.constraint(from: item) } catch let error as DraftItemError {
                problems.append(Problem(itemID: item.id, message: error.message))
            } catch {
                problems.append(Problem(itemID: item.id, message: String(describing: error)))
            }
        }
        let perIssue = Dictionary(grouping: items, by: \.issue)
        for (issue, group) in perIssue.sorted(by: { $0.key < $1.key }) where group.count > ConstraintSet.maxConstraintsPerIssue {
            problems.append(Problem(itemID: nil, message: "\(ValueFormatter().issueName(issue)) has \(group.count) rules. The limit is \(ConstraintSet.maxConstraintsPerIssue)."))
        }
        if perIssue.count > ProtocolLimits.maxIssuesPerTerms {
            problems.append(Problem(itemID: nil, message: "Rules cover \(perIssue.count) topics. The limit is \(ProtocolLimits.maxIssuesPerTerms)."))
        }
        var seen = Set<IssueKey>()
        for rule in sharing where !seen.insert(rule.issue).inserted {
            problems.append(Problem(itemID: rule.id, message: "There is already a sharing rule for \(ValueFormatter().issueName(rule.issue)). Keep one."))
        }
        return problems
    }

    /// The reviewed rules. Throws `RulesDraftError` listing every problem.
    public func build() throws -> OwnerRules {
        let problems = problems
        guard problems.isEmpty else { throw RulesDraftError(problems: problems) }
        var constraints: [IssueKey: [Constraint]] = [:]
        for item in items {
            constraints[item.issue, default: []].append(try Self.constraint(from: item))
        }
        return OwnerRules(
            constraints: try ConstraintSet(constraints),
            disclosure: sharing.map { DisclosureRule(issue: $0.issue, action: $0.action) }
        )
    }

    // MARK: Conversion

    private struct DraftItemError: Error { let message: String }

    private static func item(from constraint: Constraint, issue: IssueKey, origin: Origin) -> Item {
        var item = Item(origin: origin, issue: issue, kind: .mustBe, strength: constraint.strength)
        switch constraint.rule {
        case .within(let slots):
            item.kind = .within
            item.slots = slots.map { Slot(start: $0.start, end: $0.end) }
        case .dailyWindow(let from, let to):
            item.kind = .dailyWindow
            item.fromMinute = from
            item.toMinute = to
        case .prefers(let liked, let avoided):
            item.kind = .prefers
            item.liked = liked.map(\.value)
            item.avoided = avoided.map(\.value)
        case .atMost(let amount), .atLeast(let amount):
            if case .atMost = constraint.rule { item.kind = .atMost } else { item.kind = .atLeast }
            item.amountMinorUnits = amount.minorUnits
            item.currency = amount.currency
        case .mustBe(let flag):
            item.kind = .mustBe
            item.flag = flag
        case .countBetween(let min, let max):
            item.kind = .countBetween
            item.minCount = min
            item.maxCount = max
        }
        return item
    }

    private static func constraint(from item: Item) throws -> Constraint {
        let rule: Constraint.Rule
        switch item.kind {
        case .within:
            guard !item.slots.isEmpty else { throw DraftItemError(message: "Add a time window or delete this rule.") }
            rule = .within(try item.slots.map { slot in
                guard slot.end > slot.start else { throw DraftItemError(message: "A time window ends before it starts.") }
                do { return try TimeSlot(start: slot.start, end: slot.end) } catch {
                    throw DraftItemError(message: "A time window can be at most 14 days long.")
                }
            })
        case .dailyWindow:
            guard item.fromMinute < item.toMinute else { throw DraftItemError(message: "The start time must be before the end time.") }
            rule = .dailyWindow(from: item.fromMinute, to: item.toMinute)
        case .prefers:
            guard !item.liked.isEmpty || !item.avoided.isEmpty else {
                throw DraftItemError(message: "Add something you like or avoid, or delete this rule.")
            }
            rule = .prefers(liked: try keywords(item.liked), avoided: try keywords(item.avoided))
        case .atMost, .atLeast:
            let amount: MoneyAmount
            do { amount = try MoneyAmount(minorUnits: item.amountMinorUnits, currency: item.currency) } catch {
                throw DraftItemError(message: "Enter an amount of zero or more.")
            }
            rule = item.kind == .atMost ? .atMost(amount) : .atLeast(amount)
        case .mustBe:
            rule = .mustBe(item.flag)
        case .countBetween:
            guard 0 <= item.minCount, item.minCount <= item.maxCount, item.maxCount <= ProtocolLimits.maxCount else {
                throw DraftItemError(message: "The smallest number must not be above the largest.")
            }
            rule = .countBetween(min: item.minCount, max: item.maxCount)
        }
        do { return try Constraint(rule, strength: item.strength) } catch {
            throw DraftItemError(message: "This rule has too many entries.")
        }
    }

    private static func keywords(_ raw: [String]) throws -> [Keyword] {
        var result: [Keyword] = []
        for text in raw {
            guard let keyword = try? Keyword(text) else {
                throw DraftItemError(message: "\"\(text)\" can't be used. Use letters, numbers, spaces, and - ' & only, up to \(ProtocolLimits.maxKeywordCharacters) characters.")
            }
            if !result.contains(keyword) { result.append(keyword) }
        }
        return result
    }
}

public struct RulesDraftError: Error, Hashable, Sendable {
    public let problems: [RulesDraft.Problem]
}

// MARK: - Sharing rows

extension RulesDraft {
    /// Issues the review always shows a sharing row for, whether or not the
    /// interpreted rules mention them. Interpretation can miss a "never
    /// share" phrased in unexpected words (ADR 0161, "keep my location to
    /// myself"), so the owner must see and be able to set every one.
    public static let disclosableIssues: [IssueKey] = [.time, .activity, .budget, .place, .diet, .partySize]

    /// One issue's sharing setting as the review shows it.
    public struct SharingRow: Identifiable, Hashable, Sendable {
        public var id: IssueKey { issue }
        public let issue: IssueKey
        /// What will apply: the draft's rule, tightened by any saved rule.
        /// With no rule at all, the policy asks each time.
        public let action: DisclosureRule.Action
        /// The actions the owner may choose. A saved rule is a floor: an
        /// intent can tighten it but never loosen it (ADR 0141).
        public let choices: [DisclosureRule.Action]
        /// Set when a saved rule, not this draft, decides the action.
        public let fromSavedRules: Bool
        /// The draft's rule for this issue, for review flags.
        public let ruleID: UUID?
    }

    /// A row for every disclosable issue, plus any other issue the draft or
    /// the saved rules mention. `standing` is the saved rules' sharing, used
    /// when reviewing a Down intent; the rules editor passes none.
    public func sharingRows(standing: [DisclosureRule] = []) -> [SharingRow] {
        var floor: [IssueKey: DisclosureRule.Action] = [:]
        for rule in standing {
            floor[rule.issue] = floor[rule.issue].map { RulesMerge.restrictive($0, rule.action) } ?? rule.action
        }
        let mentioned = Set(items.map(\.issue) + sharing.map(\.issue) + floor.keys)
        let extra = mentioned.subtracting(Self.disclosableIssues).sorted()
        return (Self.disclosableIssues + extra).map { issue in
            let rule = sharing.first { $0.issue == issue }
            let saved = floor[issue]
            // Exactly what RulesMerge publishes: with no draft rule the saved
            // rule applies as is, and with neither the policy asks.
            let action = Self.merged(rule?.action, saved)
            let choices = Self.actions.filter { choice in saved.map { RulesMerge.restrictive($0, choice) == choice } ?? true }
            return SharingRow(issue: issue, action: action, choices: choices, fromSavedRules: saved != nil && saved == action && rule?.action != action, ruleID: rule?.id)
        }
    }

    /// Sets an issue's sharing. Choosing "ask each time" for an issue with no
    /// rule writes nothing, since no rule already means ask (lane G's policy).
    /// A choice looser than a saved rule is ignored.
    public mutating func setSharing(_ action: DisclosureRule.Action, for issue: IssueKey, standing: [DisclosureRule] = []) {
        let saved = standing.filter { $0.issue == issue }.map(\.action).reduce(nil) { floor, next in
            floor.map { RulesMerge.restrictive($0, next) } ?? next
        }
        if let saved, RulesMerge.restrictive(saved, action) != action { return }
        if let index = sharing.firstIndex(where: { $0.issue == issue }) {
            sharing[index].action = action
        } else if action != Self.merged(nil, saved) {
            // Only write a rule when it changes what is published. Choosing
            // "ask" over a saved allowance needs an explicit tightening rule.
            sharing.append(Sharing(id: UUID(), origin: .owner, issue: issue, action: action))
        }
    }

    /// The action RulesMerge publishes for one issue, from the draft's rule
    /// and the saved rule. No rule at all means the policy asks.
    static func merged(_ own: DisclosureRule.Action?, _ saved: DisclosureRule.Action?) -> DisclosureRule.Action {
        switch (own, saved) {
        case let (own?, saved?): RulesMerge.restrictive(saved, own)
        case let (own?, nil): own
        case let (nil, saved?): saved
        case (nil, nil): .askEachTime
        }
    }

    static let actions: [DisclosureRule.Action] = [.never, .askEachTime, .allowOnDevicePeers]
}

// MARK: - Review flags

extension RulesDraft {
    /// Advisory notes on model-produced rows that the owner's own words do not
    /// support, keyed by item or sharing rule ID. Deterministic string checks,
    /// not a model call: they point the owner at likely inventions, and the
    /// review is still mandatory for every row.
    public func reviewFlags(for utterance: String, formatter: ValueFormatter = ValueFormatter()) -> [UUID: String] {
        let words = Self.words(in: utterance)
        let numbers = Self.numbers(in: utterance)
        var flags: [UUID: String] = [:]

        for item in items where item.origin == .model {
            switch item.kind {
            case .prefers:
                let missing = (item.liked + item.avoided).filter { !Self.traces($0, to: words) }
                if !missing.isEmpty { flags[item.id] = "Not in your words: \(missing.joined(separator: ", ")). Check it." }
            case .atMost, .atLeast:
                let digits = ValueFormatter.fractionDigits(for: item.currency)
                let major = item.amountMinorUnits / Int64(pow(10, Double(digits)))
                if !numbers.contains(Int(major)) {
                    let amount = (try? MoneyAmount(minorUnits: item.amountMinorUnits, currency: item.currency)).map(formatter.money) ?? "this amount"
                    flags[item.id] = "You didn't write \(amount). Check it."
                }
            case .dailyWindow:
                let ends = [item.fromMinute, item.toMinute].filter { $0 > 0 && $0 < 1440 }
                if !ends.allSatisfy({ Self.mentionsHour(of: $0, numbers: numbers, words: words) }) {
                    flags[item.id] = "You didn't write these hours. Check them."
                }
            case .countBetween:
                if !numbers.contains(item.minCount) && !numbers.contains(item.maxCount) {
                    flags[item.id] = "You didn't write these numbers. Check them."
                }
            case .within, .mustBe:
                break
            }
        }
        for rule in sharing where rule.origin == .model && rule.action == .allowOnDevicePeers {
            flags[rule.id] = "Lets Starling share this without asking. Check you meant it."
        }
        return flags
    }

    private static func words(in text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private static func numbers(in text: String) -> Set<Int> {
        Set(text.split { !$0.isNumber }.compactMap { Int($0) })
    }

    /// Every word of the keyword appears, allowing a plural on either side.
    private static func traces(_ keyword: String, to words: Set<String>) -> Bool {
        let parts = keyword.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return !parts.isEmpty && parts.allSatisfy { part in
            words.contains(part) || words.contains(part + "s") || words.contains(part + "es")
                || (part.hasSuffix("s") && words.contains(String(part.dropLast())))
        }
    }

    private static func mentionsHour(of minute: Int, numbers: Set<Int>, words: Set<String>) -> Bool {
        let hour = minute / 60
        if hour == 12 && words.contains("noon") { return true }
        let twelveHour = hour % 12 == 0 ? 12 : hour % 12
        return numbers.contains(hour) || numbers.contains(twelveHour)
    }
}

// MARK: - Merging

/// Combines the owner's standing rules with one Down intent. `DownService`
/// takes a single `OwnerRules`, so the app merges before calling it.
public enum RulesMerge {
    /// Constraints on the same issue accumulate (both must hold). For sharing,
    /// the most restrictive rule for each issue wins, so an intent can never
    /// loosen a standing "never share" (ADR 0141).
    public static func intent(_ intent: OwnerRules, standing: OwnerRules) throws -> OwnerRules {
        var constraints = standing.constraints.constraints
        for (issue, list) in intent.constraints.constraints {
            constraints[issue, default: []].append(contentsOf: list)
        }
        var sharing: [IssueKey: DisclosureRule.Action] = [:]
        for rule in standing.disclosure + intent.disclosure {
            sharing[rule.issue] = sharing[rule.issue].map { restrictive($0, rule.action) } ?? rule.action
        }
        return OwnerRules(
            constraints: try ConstraintSet(constraints),
            disclosure: sharing.keys.sorted().map { DisclosureRule(issue: $0, action: sharing[$0]!) }
        )
    }

    static func restrictive(_ a: DisclosureRule.Action, _ b: DisclosureRule.Action) -> DisclosureRule.Action {
        let order: [DisclosureRule.Action] = [.never, .askEachTime, .allowOnDevicePeers]
        return order.firstIndex(of: a)! <= order.firstIndex(of: b)! ? a : b
    }
}
