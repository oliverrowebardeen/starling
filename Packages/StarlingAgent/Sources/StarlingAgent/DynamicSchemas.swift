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
