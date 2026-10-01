import FoundationModels
@testable import StarlingAgent
import StarlingCore
import Testing

@Suite struct MatchSchemaTests {
    let food = try! Keyword("food")
    let study = try! Keyword("study")
    let movie = try! Keyword("movie")
    let boba = try! Keyword("boba run")

    /// Issue #9: "none" must be a valid answer, and it must mean no match.
    @Test func noneMeansNoMatch() throws {
        let matches = try OutputMapping.bestOffers([RawChoice(offer: "none")], wanted: [food], offered: [movie])
        #expect(matches.isEmpty)
    }

    @Test func choicesBecomeMatchesWithTheModelsStrength() throws {
        let matches = try OutputMapping.bestOffers(
            [RawChoice(offer: "boba run", same: false), RawChoice(offer: "none")],
            wanted: [food, study], offered: [movie, boba]
        )
        #expect(matches == [KeywordMatch(wanted: food, offered: boba, strength: .satisfies)])
        let same = try OutputMapping.bestOffers([RawChoice(offer: "movie", same: true)], wanted: [movie], offered: [movie])
        #expect(same == [KeywordMatch(wanted: movie, offered: movie, strength: .equivalent)])
    }

    @Test func rejectsInventedOffersAndMiscountedChoices() {
        #expect(throws: AgentModelError.self) { _ = try OutputMapping.bestOffers([RawChoice(offer: "pizza")], wanted: [food], offered: [movie]) }
        #expect(throws: AgentModelError.self) { _ = try OutputMapping.bestOffers([], wanted: [food], offered: [movie]) }
    }

    @Test func readsGeneratedContentAndDropsDuplicates() throws {
        let none = try Keyword("none")
        let schema = try MatchSchema(wanted: [food, food, study], offered: [movie, boba, none, boba])
        #expect(schema.wanted == [food, study])
        #expect(schema.offered == [movie, boba])
        let content = GeneratedContent(properties: [
            "want:food": "boba run", "same:food": false,
            "want:study": "none", "same:study": false,
        ])
        #expect(try schema.matches(from: content) == [KeywordMatch(wanted: food, offered: boba, strength: .satisfies)])
    }

    /// Codex review of PR #19: with names "food" and "food same", the wants
    /// [food, "food same"] made two properties called "food same", and
    /// GenerationSchema rejected the schema. A colon, which no Keyword can
    /// contain, keeps every name distinct (ADR 0162).
    @Test func wantEndingInSameDoesNotCollide() throws {
        let foodSame = try Keyword("food same")
        let schema = try MatchSchema(wanted: [food, foodSame], offered: [movie, boba])
        let content = GeneratedContent(properties: [
            "want:food": "boba run", "same:food": false,
            "want:food same": "movie", "same:food same": true,
        ])
        #expect(try schema.matches(from: content) == [
            KeywordMatch(wanted: food, offered: boba, strength: .satisfies),
            KeywordMatch(wanted: foodSame, offered: movie, strength: .equivalent),
        ])
    }
}
