@testable import StarlingAgent
import StarlingCore
import StarlingFakes
import Foundation
import Testing

/// Keyword chips in the owner's own words (device test, 2026-10-02; ADRs
/// 0161 and 0212).
@Suite struct OwnersWordsTests {
    func picks(_ phrases: [String], in utterance: String, place: Bool = false) -> [String] {
        var own = OwnersWords(utterance)
        return phrases.flatMap { own.pick($0, place: place, many: true) }.map(\.text)
    }

    @Test func aParaphraseBecomesTheOwnersPhrase() {
        #expect(picks(["Watch Movie"], in: "movie night tonight in Elm Hall") == ["movie night"])
        #expect(picks(["play basketball"], in: "who wants to play basketball this afternoon") == ["basketball"])
    }

    @Test func aCutOffPhraseGrowsToTheWholePhrase() {
        #expect(picks(["trip"], in: "find a time invite for IKEA trip") == ["IKEA trip"])
        #expect(picks(["run"], in: "Costco run tomorrow afternoon") == ["Costco run"])
        #expect(picks(["soccer"], in: "pickup soccer at 5 today") == ["pickup soccer"])
        #expect(picks(["ski"], in: "find a time for the Tahoe ski trip") == ["Tahoe ski trip"])
    }

    @Test func theOwnersSpellingIsKept() {
        #expect(picks(["ikea trip"], in: "find a time invite for IKEA trip") == ["IKEA trip"])
        #expect(picks(["elm hall"], in: "movie night tonight in Elm Hall", place: true) == ["Elm Hall"])
    }

    @Test func timesPeoplePricesAndRuleWordsAreNeverAnActivity() {
        #expect(picks(["tonight"], in: "boba tonight with whoever's free").isEmpty)
        #expect(picks(["friends"], in: "karaoke with close friends").isEmpty)
        #expect(picks(["invite"], in: "find a time invite for IKEA trip").isEmpty)
        #expect(picks(["$20"], in: "dinner under $20").isEmpty)
        #expect(picks(["not far"], in: "pho, not far").isEmpty)
        // "night" ends an activity only after one, never on its own.
        #expect(picks(["night"], in: "karaoke friday night").isEmpty)
        #expect(picks(["game night"], in: "game night friday with Maya") == ["game night"])
        #expect(picks(["boba tonight"], in: "boba tonight with whoever's free") == ["boba"])
    }

    @Test func aPhraseStopsAtPunctuation() {
        #expect(picks(["pho"], in: "let's get pho, nothing far") == ["pho"])
    }

    @Test func noWordIsInTwoChips() {
        #expect(picks(["movie night", "movie"], in: "movie night tonight") == ["movie night"])
        var own = OwnersWords("study session at the library")
        #expect(own.pick("library").map(\.text) == ["library"])
        #expect(own.pick("the library", place: true).isEmpty)
    }

    @Test func aDistanceIsThePlaceInTheOwnersWords() {
        #expect(picks(["nearby"], in: "boba tonight, nothing far", place: true) == ["nothing far"])
        #expect(picks(["far"], in: "drinks later, not too far", place: true) == ["not too far"])
        #expect(picks(["campus"], in: "coffee near campus", place: true) == ["campus"])
        #expect(picks(["nearby"], in: "ramen near downtown on thursday", place: true) == ["downtown"])
        // Not for an activity, and not "close friends".
        #expect(picks(["nearby"], in: "boba, nothing far").isEmpty)
        #expect(picks(["close"], in: "karaoke with close friends", place: true).isEmpty)
    }

    @Test func aStretchOfTheMessageIsItsFirstPhrase() {
        #expect(picks(["dinner tonight under $20 with Maya and Jake"], in: "dinner tonight under $20 with Maya and Jake") == ["dinner"])
        #expect(picks(["walk around the lake"], in: "anyone free for a walk around the lake") == ["walk"])
        #expect(picks(["ice cream with priya"], in: "ice cream with Priya after 9 tonight") == ["ice cream"])
        #expect(picks(["movie night tonight in Elm Hall"], in: "movie night tonight in Elm Hall") == ["movie night"])
        // Joined by "or" or "and", both are chips.
        #expect(picks(["bowling or arcade"], in: "bowling or arcade tonight") == ["bowling", "arcade"])
    }

    @Test func aFriendsNameIsNeverAnActivity() {
        var own = OwnersWords("hot pot tonight with Sam", names: ["Sam"])
        #expect(own.pick("sam").isEmpty)
        #expect(own.pick("hot pot").map(\.text) == ["hot pot"])
    }

    @Test func aPhraseAfterNoIsSomethingToAvoid() {
        var own = OwnersWords("cheap lunch today, under 10 bucks, no sushi")
        #expect(own.pick("sushi") == [OwnersWords.Picked(text: "sushi", negated: true)])
        #expect(own.pick("lunch") == [OwnersWords.Picked(text: "cheap lunch", negated: false)])
    }

    @Test func aPhraseNotInTheMessageIsDropped() {
        #expect(picks(["sushi"], in: "boba tonight").isEmpty)
    }

    /// The whole intent, through `SkillOutputMapping`, for both phrases from
    /// the device test.
    @Test func theDeviceTestPhrasesMapToTheOwnersWords() throws {
        let now = Date(timeIntervalSince1970: 1_790_967_600)
        let utc = TimeZone(identifier: "UTC")!
        let movie = try SkillOutputMapping.parsed(
            RawIntent(rules: RawRules(day: .relative(0), wants: ["Watch Movie"]), extras: [.place: ["hall"]]),
            utterance: "movie night tonight in Elm Hall", skill: SampleSkills.downFor, now: now, timeZone: utc
        )
        #expect(movie.constraints[.activity] == [try Constraint(.prefers(liked: [try Keyword("movie night")], avoided: []), strength: .soft)])
        #expect(movie.constraints[.place] == [try Constraint(.prefers(liked: [try Keyword("Elm Hall")], avoided: []), strength: .soft)])
        let trip = try SkillOutputMapping.parsed(
            RawIntent(rules: RawRules(wants: ["invite", "trip"])),
            utterance: "find a time invite for IKEA trip", skill: SampleSkills.findATime, now: now, timeZone: utc
        )
        #expect(trip.constraints[.activity] == [try Constraint(.prefers(liked: [try Keyword("IKEA trip")], avoided: []), strength: .soft)])
    }
}
