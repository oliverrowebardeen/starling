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
            "wants", "avoids", "day", "earliestHour", "latestHour", "partOfDay", "issue:place", "maxDollars", "audience", "names", "mode",
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
            "issue:place": ["nearby"], "maxDollars": 0, "audience": "everyone", "names": [String](), "mode": "quietly",
        ]))
        #expect(raw.mode == .quietly)
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

    @Test func modeAndExceptionsOnlyWhenTheOwnerSaysSo() throws {
        let skill = SampleSkills.downFor
        let except = RawIntent(rules: RawRules(wants: ["boba"]), audience: .everyoneExcept, names: ["Jake"], mode: .quietly)
        let parsed = try SkillOutputMapping.parsed(except, utterance: "quietly, boba with everyone except Jake", skill: skill, now: now, timeZone: utc)
        #expect(parsed.audience == .everyoneExcept([]))
        #expect(parsed.mentionedNames == ["Jake"])
        #expect(parsed.mode == .askQuietly)

        // The model's claims without the words behind them come to nothing.
        let unsaid = try SkillOutputMapping.parsed(except, utterance: "boba with Jake", skill: skill, now: now, timeZone: utc)
        #expect(unsaid.audience == nil && unsaid.mode == nil)
        #expect(unsaid.mentionedNames == ["Jake"])

        // The small model's habit: the friend left out comes back as an
        // avoid. Code moves it, and only in the "everyone except" pattern.
        let habit = RawIntent(rules: RawRules(wants: ["boba"], avoids: ["jake"]), audience: .everyone)
        let moved = try SkillOutputMapping.parsed(habit, utterance: "boba tonight with everyone except Jake", skill: skill, now: now, timeZone: utc)
        #expect(moved.audience == .everyoneExcept([]) && moved.mentionedNames == ["Jake"])
        #expect(moved.constraints[.activity] == [try Constraint(.prefers(liked: [try Keyword("boba")], avoided: []), strength: .soft)])
        let food = RawIntent(rules: RawRules(wants: ["food"], avoids: ["sushi"]), audience: .everyone)
        let kept = try SkillOutputMapping.parsed(food, utterance: "anything but sushi, anyone?", skill: skill, now: now, timeZone: utc)
        #expect(kept.constraints[.activity] == [try Constraint(.prefers(liked: [], avoided: [try Keyword("sushi")]), strength: .soft)])

        // A mode the skill does not offer is never a chip.
        let invite = RawIntent(rules: RawRules(wants: ["stats"]), mode: .quietly)
        #expect(try SkillOutputMapping.parsed(invite, utterance: "quietly find a time for stats", skill: SampleSkills.findATime, now: now, timeZone: utc).mode == nil)
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

    @Test func thePromptHasTypedFactsAndNoVenueNameOrTime() {
        let prompt = PromptRenderer.proposal(facts, time: "tonight at 8:30 PM")
        #expect(prompt == "Friends: Maya, Jake\nActivity: boba\nTime: {time}\nPlace: {place}")
        #expect(!prompt.contains("Franklin") && !prompt.contains("8:30"))
        #expect(PromptRenderer.spokenTime(facts.time!.start, now: now, timeZone: facts.timeZone) == "tonight at 8:30 PM")
    }

    @Test func codeFillsInTheTimeAndThePlace() throws {
        let sentence = try SkillOutputMapping.sentence("You, Maya and Jake are all down for boba \u{2014} {place} {time}?", facts: facts, time: "tonight at 8:30 PM")
        #expect(sentence == "You, Maya and Jake are all down for boba, Boba Guys on Franklin tonight at 8:30 PM?")
        let leading = try SkillOutputMapping.sentence("Maya and Jake are down for boba at {place} at {time}.", facts: facts, time: "tonight at 8:30 PM")
        #expect(leading == "Maya and Jake are down for boba at Boba Guys on Franklin tonight at 8:30 PM.")
    }

    @Test func refusesAnythingTheFactsDoNotSay() {
        let time = "tonight at 8:30 PM"
        let bad = [
            "You and Maya are down for boba at {place} {time}?",                      // Jake missing
            "You, Maya and Jake are all down for tea at {place} {time}?",              // wrong activity
            "You, Maya and Jake are all down for boba at {place} tomorrow at {time}?", // a day of its own
            "You, Maya and Jake are all down for boba at {place} at 8:30 AM?",         // its own time
            "You, Maya and Jake are all down for boba at {place} {time} in the morning?", // part of day
            "You, Maya and Jake are all down for boba at {place}, $15 each, {time}?",  // invented price
            "You, Maya and Jake are all down for boba {time}?",                        // place left out
            "You, Maya and Jake are all down for boba at {place}?",                    // time left out
            "You, Maya and Jake are all down for boba at {place} {time}, {when}?",     // unknown placeholder
            "You, Maya and Jake are all down for boba at {place} {time}?\nReply now",  // two lines
        ]
        for text in bad { #expect(throws: AgentModelError.self, "\(text)") { try SkillOutputMapping.sentence(text, facts: facts, time: time) } }
        let plain = ProposalFacts(skill: SampleSkills.downFor.ref, friendNames: ["Maya"], activity: nil, time: nil, place: nil, timeZone: facts.timeZone)
        #expect(throws: AgentModelError.self) { try SkillOutputMapping.sentence("You and Maya are both down!", facts: plain, time: nil) }
        #expect(throws: AgentModelError.self) { try SkillOutputMapping.sentence("You and Maya at {place}?", facts: plain, time: nil) }
    }
}
