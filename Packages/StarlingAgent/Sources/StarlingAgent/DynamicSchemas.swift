import FoundationModels
import StarlingCore

// Schemas built per call with DynamicGenerationSchema (iOS and macOS 26.0+),
// so the model can only produce values that exist for this call. A static
// @Generable type cannot know which offers or options a call has.

/// "For each want, which offer satisfies it, if any?"
///
/// Replaces a list of (want, offer) pairs. With the list, the only way to
/// say "no match" was an empty list, and the model never produced one:
/// red-team issue #9 saw food match movie in 24 of 24 greedy trials. Here
/// every want gets an explicit choice, and `none` comes first.
package struct MatchSchema {
    package static let noMatch = "none"

    package let wanted: [Keyword]
    package let offered: [Keyword]
    package let schema: GenerationSchema

    package init(wanted: [Keyword], offered: [Keyword]) throws {
        self.wanted = Self.unique(wanted)
        // An offered keyword spelled "none" could never be told apart from
        // the no-match choice, so it is not offered.
        self.offered = Self.unique(offered).filter { $0.value != Self.noMatch }
        // Defined once and referenced, so a long offer list is not repeated
        // for every want (ADR 0002 budget).
        let offer = DynamicGenerationSchema(name: "Offer", anyOf: [Self.noMatch] + self.offered.map(\.value))
        var properties: [DynamicGenerationSchema.Property] = []
        for want in self.wanted {
            properties.append(DynamicGenerationSchema.Property(
                name: Self.choiceName(want),
                description: "Offer that gives the owner \(want.value). none if every offer is a different kind of thing",
                schema: DynamicGenerationSchema(referenceTo: "Offer")
            ))
            properties.append(DynamicGenerationSchema.Property(
                name: Self.sameName(want),
                description: "True if that offer means the same as \(want.value)",
                schema: DynamicGenerationSchema(type: Bool.self)
            ))
        }
        schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Matches", properties: properties), dependencies: [offer])
    }

    /// Reads the model's choices. Throws on anything the schema should
    /// have made impossible, rather than trusting it.
    package func matches(from content: GeneratedContent) throws -> [KeywordMatch] {
        let choices = try wanted.map { want -> RawChoice in
            let offer = try content.value(String.self, forProperty: Self.choiceName(want))
            let same = (try? content.value(Bool.self, forProperty: Self.sameName(want))) ?? false
            return RawChoice(offer: offer, same: same)
        }
        return try OutputMapping.bestOffers(choices, wanted: wanted, offered: offered)
    }

    static func choiceName(_ want: Keyword) -> String { want.value }
    static func sameName(_ want: Keyword) -> String { "\(want.value) same" }

    private static func unique(_ keywords: [Keyword]) -> [Keyword] {
        var seen = Set<Keyword>()
        return keywords.filter { seen.insert($0).inserted }
    }
}

/// One want's answer, before validation.
package struct RawChoice: Hashable, Sendable {
    package var offer: String
    package var same: Bool

    package init(offer: String, same: Bool = false) {
        self.offer = offer
        self.same = same
    }
}

extension OutputMapping {
    /// Maps per-want choices, in `wanted` order, to matches. `none` means no
    /// match; any other value must be one of the offers.
    package static func bestOffers(_ choices: [RawChoice], wanted: [Keyword], offered: [Keyword]) throws -> [KeywordMatch] {
        guard choices.count == wanted.count else { throw AgentModelError.invalidOutput("\(choices.count) choices for \(wanted.count) wants") }
        return try zip(wanted, choices).compactMap { want, choice in
            if choice.offer == MatchSchema.noMatch { return nil }
            guard let offer = offered.first(where: { $0.value == choice.offer }) else {
                throw AgentModelError.invalidOutput("offer \(choice.offer) not offered")
            }
            return KeywordMatch(wanted: want, offered: offer, strength: choice.same ? .equivalent : .satisfies)
        }
    }
}

/// The move schema for one decision, with a property only for each issue
/// the proposal is about. The Phase 0 bench saw a time-only negotiation
/// answer with "activity option 2" because the static schema always had an
/// activity field; here that field does not exist unless activity is in play.
///
/// Hard limits are enforced by the schema, not asked of the model: accept
/// is not offered when the proposal breaks a limit, a counter must set every
/// broken issue, and option lists hold only compliant options. The Phase 0
/// `brokenItems` field, which asked the model to name conflicts first, is
/// gone: code knows them, and as an array of a one-choice enum it made the
/// macOS 26.7 model service fail (ModelManagerError 1032).
package struct DecisionSchema {
    package static let moves = ["accept", "counter", "reject"]

    package let schema: GenerationSchema
    /// Property names in generation order, for tests and debugging.
    package let properties: [String]
    /// The moves offered. `["reject"]` alone means no model call is needed.
    package let moves: [String]

    package init(prompt: DecisionPrompt, proposal: Proposal) throws {
        var properties: [DynamicGenerationSchema.Property] = []
        var names: [String] = []
        func add(_ name: String, _ property: DynamicGenerationSchema.Property) {
            names.append(name)
            properties.append(property)
        }
        let hasTime = proposal.terms[.time] != nil && !prompt.timeOptions.isEmpty
        let hasActivity = proposal.terms[.activity] != nil && !prompt.activityOptions.isEmpty
        var budget: ClosedRange<Int>?
        if case .amount = proposal.terms[.budget] { budget = prompt.budgetRange }
        // A counter keeps the proposal's value for any issue it leaves out,
        // so it must change every broken issue, and needs a field to do it.
        let fixable: [IssueKey: Bool] = [.time: hasTime, .activity: hasActivity, .budget: budget != nil]
        let canCounter = prompt.brokenIssues.allSatisfy { fixable[$0] ?? false }
        moves = Self.moves.filter { move in
            switch move {
            // Accepting terms that break a limit is never offered.
            case "accept": prompt.brokenIssues.isEmpty
            case "counter": canCounter
            default: true
            }
        }
        add("move", DynamicGenerationSchema.Property(
            name: "move",
            schema: DynamicGenerationSchema(name: "Move", anyOf: moves)
        ))
        if hasTime {
            add("timeOption", Self.option("timeOption", "Counter only: time option number", count: prompt.timeOptions.count, required: prompt.brokenIssues.contains(.time)))
        }
        if hasActivity {
            add("activityOption", Self.option("activityOption", "Counter only: activity option number", count: prompt.activityOptions.count, required: prompt.brokenIssues.contains(.activity)))
        }
        if let budget {
            add("budgetDollars", DynamicGenerationSchema.Property(
                name: "budgetDollars",
                description: "Counter only: budget in whole dollars",
                schema: DynamicGenerationSchema(type: Int.self, guides: [.range(budget)]),
                isOptional: !prompt.brokenIssues.contains(.budget)
            ))
        }
        self.properties = names
        schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Decision", properties: properties), dependencies: [])
    }

    /// Reads the model's move. Anything the schema did not offer stays nil,
    /// and OutputMapping.move validates the rest.
    package func move(from content: GeneratedContent) throws -> RawMove {
        let kind: RawMove.Kind = switch try content.value(String.self, forProperty: "move") {
        case "accept": .accept
        case "counter": .counter
        case "reject": .reject
        case let other: throw AgentModelError.invalidOutput("move \(other) not offered")
        }
        guard moves.contains(String(describing: kind)) else {
            throw AgentModelError.invalidOutput("move \(kind) not offered")
        }
        func number(_ name: String) throws -> Int? {
            properties.contains(name) ? try content.value(Int?.self, forProperty: name) : nil
        }
        return RawMove(kind: kind, timeOption: try number("timeOption"), activityOption: try number("activityOption"), budgetDollars: try number("budgetDollars"))
    }

    /// Whole dollars the model may name; matches the Core money limit.
    static let maxDollars = Int(ProtocolLimits.maxMoneyMinorUnits / 100)

    private static func option(_ name: String, _ description: String, count: Int, required: Bool) -> DynamicGenerationSchema.Property {
        DynamicGenerationSchema.Property(
            name: name,
            description: description,
            schema: DynamicGenerationSchema(type: Int.self, guides: [.range(1...count)]),
            isOptional: !required
        )
    }
}
