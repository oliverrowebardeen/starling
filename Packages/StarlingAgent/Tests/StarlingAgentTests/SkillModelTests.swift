import Foundation
import FoundationModels
@testable import StarlingAgent
import StarlingCore
import StarlingFakes
import Testing

@Suite struct RouteSchemaTests {
    let skills = [SampleSkills.downFor, SampleSkills.findATime, SampleSkills.pickAPlace]

    @Test func onlySkillsThatCanRunOrNone() throws {
        let schema = try RouteSchema(skills: skills)
        #expect(schema.choices == ["down_for", "find_a_time", "pick_a_place", "none"])
        #expect(try schema.skill(from: GeneratedContent(properties: ["skill": "find_a_time"])) == .findATime)
        #expect(try schema.skill(from: GeneratedContent(properties: ["skill": "none"])) == nil)
        // A skill that is not offered (switched off, not in this build) is refused.
        #expect(throws: AgentModelError.self) { try RouteSchema(skills: [SampleSkills.downFor]).skill(named: "find_a_time") }
    }

    @Test func thePromptHasTheOwnersWordsAndTheSkillsOwnWordsOnly() throws {
        let prompt = PromptRenderer.route(try OwnerUtterance("boba tonight with whoever's free"), skills: skills)
        #expect(prompt.contains("- down_for: Down for… See who's up for something. Checks which friends are up for doing something now or soon. Reads: what they want to do, such as boba or a walk; when, such as tonight after 7 (optional); where or how far, such as nearby (optional); the most they want to spend (optional)."))
        #expect(prompt.contains("- pick_a_place: Pick a place Agree on where. Combines everyone's preferences into one choice, such as a venue."))
        #expect(prompt.hasSuffix("Owner: boba tonight with whoever's free"))
    }
}

@Suite struct IntentSchemaTests {
    let now = Date(timeIntervalSince1970: 1_790_683_200) // Tue 2026-09-29 12:00 UTC
    let utc = TimeZone(identifier: "UTC")!

    @Test func fieldsFollowTheSkillsSlots() throws {
        #expect(try IntentGenerationSchema(skill: SampleSkills.downFor).properties == [
            "wants", "avoids", "day", "earliestHour", "latestHour", "partOfDay", "issue:place", "maxDollars", "audience", "names",
        ])
        #expect(try IntentGenerationSchema(skill: SampleSkills.findATime).properties == [
            "day", "earliestHour", "latestHour", "partOfDay", "wants", "avoids", "audience", "names",
        ])
        // Swap photos asks for no audience.
        #expect(try IntentGenerationSchema(skill: SampleSkills.swapPhotos).properties == ["issue:photos"])
    }

    @Test func readsGeneratedContentWithSentinels() throws {
        let schema = try IntentGenerationSchema(skill: SampleSkills.downFor)
        let raw = try schema.raw(from: GeneratedContent(properties: [
            "wants": ["boba"], "avoids": [String](), "day": "tonight", "earliestHour": 7, "latestHour": 24, "partOfDay": "none",
            "issue:place": ["nearby"], "maxDollars": 0, "audience": "everyone", "names": [String](),
        ]))
        #expect(raw.rules.day == .relative(0))
        #expect(raw.rules.partOfDay == .evening)
        #expect(raw.rules.earliestHour == 7 && raw.rules.latestHour == nil && raw.rules.maxDollars == nil)
        #expect(raw.extras == [.place: ["nearby"]])
        #expect(raw.audience == .everyone)
    }

    @Test func chipsForTheMockupsSentence() throws {
        // "boba tonight with whoever's free, nothing far" (mockup New).
        let raw = RawIntent(
            rules: RawRules(day: .relative(0), partOfDay: .evening, earliestHour: 19, wants: ["boba"]),
            extras: [.place: ["not far"]], audience: .everyone
        )
        let parsed = try SkillOutputMapping.parsed(raw, utterance: "boba tonight after 7 with whoever's free, nothing far", skill: SampleSkills.downFor, now: now, timeZone: utc)
        #expect(parsed.constraints[.activity] == [try Constraint(.prefers(liked: [try Keyword("boba")], avoided: []), strength: .soft)])
        #expect(parsed.constraints[.time] == [try Constraint(.within([try TimeSlot(start: now.addingTimeInterval(7 * 3600), end: now.addingTimeInterval(12 * 3600))]))])
        #expect(parsed.constraints[.place] == [try Constraint(.prefers(liked: [try Keyword("not far")], avoided: []), strength: .soft)])
        #expect(parsed.audience == .allFriends)
        // Expires when the window ends, midnight.
        #expect(parsed.expiresAt == Timestamp(now.addingTimeInterval(12 * 3600)))
    }

    @Test func nothingTheOwnerDidNotSaySurvives() throws {
        let raw = RawIntent(
            rules: RawRules(day: .relative(1), wants: ["sushi", "coffee"], maxDollars: 40, neverShare: [.location]),
            extras: [.place: ["downtown"]], audience: .closeFriends, names: ["Priya", "Jake"]
        )
        let parsed = try SkillOutputMapping.parsed(raw, utterance: "coffee with Priya", skill: SampleSkills.downFor, now: now, timeZone: utc)
        #expect(parsed.constraints[.activity] == [try Constraint(.prefers(liked: [try Keyword("coffee")], avoided: []), strength: .soft)])
        #expect(parsed.constraints[.time].isEmpty && parsed.constraints[.budget].isEmpty && parsed.constraints[.place].isEmpty)
        // A named friend makes it a picked audience, resolved by the app.
        #expect(parsed.mentionedNames == ["Priya"])
        #expect(parsed.audience == nil)
        // No time named: the request lasts three hours.
        #expect(parsed.expiresAt == Timestamp(now.addingTimeInterval(3 * 3600)))
    }

    @Test func namesKeepTheOwnersSpellingAndSkipGroupWords() {
        #expect(SkillOutputMapping.grounded(names: ["maya", "friends", "Mary Jane", "Bob"], in: "Down for pho with Maya and mary jane, and my friends") == ["Maya", "mary jane"])
    }
}

@Suite struct ProposalSentenceTests {
    let now = Date(timeIntervalSince1970: 1_790_967_600) // Fri 2026-10-02 19:00 UTC
    var facts: ProposalFacts {
        ProposalFacts(
            skill: SampleSkills.downFor.ref, friendNames: ["Maya", "Jake"], activity: try! Keyword("boba"),
            time: try! TimeSlot(start: now.addingTimeInterval(5400), end: now.addingTimeInterval(9000)),
            place: try! PlaceName("Boba Guys on Franklin"), timeZone: TimeZone(identifier: "UTC")!
        )
    }

    @Test func thePromptHasTypedFactsAndNoVenueName() {
        let prompt = PromptRenderer.proposal(facts, time: "tonight at 8:30 PM")
        #expect(prompt == "Friends: Maya, Jake\nActivity: boba\nTime: tonight at 8:30 PM\nPlace: {place}")
        #expect(!prompt.contains("Franklin"))
        #expect(PromptRenderer.spokenTime(facts.time!.start, now: now, timeZone: facts.timeZone) == "tonight at 8:30 PM")
    }

    @Test func acceptsASentenceThatSaysWhatTheFactsSay() throws {
        let sentence = try SkillOutputMapping.sentence("You, Maya and Jake are all down for boba \u{2014} {place} tonight at 8:30?", facts: facts, time: "tonight at 8:30 PM")
        #expect(sentence == "You, Maya and Jake are all down for boba, Boba Guys on Franklin tonight at 8:30?")
    }

    @Test func refusesAnythingTheFactsDoNotSay() {
        let time = "tonight at 8:30 PM"
        let bad = [
            "You and Maya are down for boba at {place} tonight at 8:30?",            // Jake missing
            "You, Maya and Jake are all down for tea at {place} tonight at 8:30?",    // wrong activity
            "You, Maya and Jake are all down for boba at {place} tonight at 9:30?",   // invented time
            "You, Maya and Jake are all down for boba at {place}, $15 each, at 8:30?", // invented price
            "You, Maya and Jake are all down for boba tonight at 8:30?",              // place left out
            "You, Maya and Jake are all down for boba at {place} at 8:30?\nReply now", // two lines
        ]
        for text in bad { #expect(throws: AgentModelError.self) { try SkillOutputMapping.sentence(text, facts: facts, time: time) } }
        let plain = ProposalFacts(skill: SampleSkills.downFor.ref, friendNames: ["Maya"], activity: nil, time: nil, place: nil, timeZone: facts.timeZone)
        #expect(throws: AgentModelError.self) { try SkillOutputMapping.sentence("You and Maya are both down!", facts: plain, time: nil) }
        #expect(throws: AgentModelError.self) { try SkillOutputMapping.sentence("You and Maya at {place}?", facts: plain, time: nil) }
    }
}
