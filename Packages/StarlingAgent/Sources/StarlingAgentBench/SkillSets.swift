import Foundation
import StarlingCore

// Labeled sets for the model's Phase 1.5 jobs (ADR 0016), measured the ADR
// 0160 way. Both held-out sets were written at the same time as the tuning
// sets, before any measurement, and are run only to report: a fix for a
// held-out failure must come with fresh held-out items.

/// An owner's words in New and the skill they should route to.
public struct RoutingLabel: Hashable, Sendable, Codable {
    public let text: String
    /// `down_for`, `find_a_time`, `pick_a_place`, or nil for none.
    public let skill: String?

    public init(_ text: String, _ skill: String?) {
        self.text = text
        self.skill = skill
    }
}

public enum RoutingSet {
    public static let labels: [RoutingLabel] = [
        // Down for...: an activity, now or soon, with whoever is up for it.
        .init("boba tonight with whoever's free", "down_for"),
        .init("anyone down for tacos after 8?", "down_for"),
        .init("want to grab dinner tonight, under $20", "down_for"),
        .init("free now, up for a walk", "down_for"),
        .init("who wants to play basketball this afternoon", "down_for"),
        .init("karaoke friday night?", "down_for"),
        .init("coffee in an hour with whoever", "down_for"),
        .init("let's get pho, nothing far", "down_for"),
        .init("movie tonight anyone?", "down_for"),
        .init("ice cream after class", "down_for"),
        .init("looking for people to study with at the library tonight", "down_for"),
        .init("pickup soccer at 5", "down_for"),
        .init("drinks later, $30 max", "down_for"),
        .init("bored, anyone want to hang out tonight", "down_for"),
        // Device test, 2026-10-02.
        .init("movie night tonight in Elm Hall", "down_for"),
        .init("Costco run tomorrow afternoon", "down_for"),

        // Find a time: agreeing on when, usually further out.
        .init("find a time next week for stats study group", "find_a_time"),
        .init("when can Priya and I meet this week", "find_a_time"),
        .init("schedule a call with mom sometime this weekend", "find_a_time"),
        .init("need an hour with Jake before friday to plan the trip", "find_a_time"),
        .init("find a time for the four of us to do dinner next month", "find_a_time"),
        .init("when is everyone free next tuesday", "find_a_time"),
        .init("set up a time to review the project with Maya", "find_a_time"),
        .init("pick a day next week for game night", "find_a_time"),
        .init("find 30 minutes with dad tomorrow", "find_a_time"),
        .init("when works for book club in october", "find_a_time"),
        .init("find a time invite for IKEA trip", "find_a_time"),

        // Pick a place: agreeing on where.
        .init("where should we eat friday", "pick_a_place"),
        .init("pick a place for dinner with Maya and Jake", "pick_a_place"),
        .init("somewhere cheap for lunch near campus", "pick_a_place"),
        .init("find a vegetarian spot for dinner tonight", "pick_a_place"),
        .init("where should the group go for brunch", "pick_a_place"),
        .init("choose a bar near Franklin", "pick_a_place"),
        .init("suggest a coffee shop for our study session", "pick_a_place"),
        .init("where should we meet up downtown", "pick_a_place"),

        // None: not a request to plan something with friends.
        .init("what's the weather tomorrow", nil),
        .init("remind me to call mom", nil),
        .init("thanks!", nil),
        .init("never share my location", nil),
        .init("how do I pair a new friend", nil),
        .init("turn off notifications", nil),
        .init("what time is it in Tokyo", nil),
        .init("delete my last plan", nil),
    ]

    public static let heldOut: [RoutingLabel] = [
        .init("who's up for bowling tonight", "down_for"),
        .init("anyone free for lunch right now", "down_for"),
        .init("up for a late night snack run", "down_for"),
        .init("want to go climbing after 6, cheap", "down_for"),
        .init("hot pot tonight with the usual crew", "down_for"),
        .init("beach tomorrow if anyone's around", "down_for"),
        .init("quick coffee before my 3pm", "down_for"),
        .init("trivia night tonight with Sam", "down_for"),
        .init("when can we all do a video call next week", "find_a_time"),
        .init("get the roommates together sometime this week to talk about chores", "find_a_time"),
        .init("find a free evening next week with Sam", "find_a_time"),
        .init("when are Maya and Jake both free saturday", "find_a_time"),
        .init("find a time for our NYC trip", "find_a_time"),
        .init("where should we go for Jake's birthday dinner", "pick_a_place"),
        .init("need a quiet cafe to work from with Priya", "pick_a_place"),
        .init("pick somewhere with outdoor seating for saturday", "pick_a_place"),
        .init("what's a good spot for ramen near us", "pick_a_place"),
        .init("show my history", nil),
        .init("how much did I spend last month", nil),
        .init("is my phone paired with Maya", nil),
        .init("good morning", nil),
        .init("make my budget private", nil),
    ]
}

/// An owner's words for a skill (Down for... unless it says) and the chips
/// they should become.
public struct ChipLabel: Hashable, Sendable, Codable {
    /// The skill the words are for: `down_for` or `find_a_time`.
    public let skill: String
    /// Day, hours, activities, and budget, scored as in ADR 0160.
    public let fields: InterpretationLabel
    /// Each item is one expected place word, with `|` between spellings.
    public let place: [String]
    /// "everyone", "close", "except", or nil when the owner said nobody in
    /// particular. With "except", `names` are the friends left out.
    public let audience: String?
    /// Names of friends or of the owner's groups, as written.
    public let names: [String]
    /// "quietly" or "invite" when the owner's words ask for a send mode.
    public let mode: String?

    public init(
        _ text: String, day: InterpretationLabel.Day? = nil, from: ClosedRange<Int> = 0...0, to: ClosedRange<Int> = 24...24,
        wants: [String] = [], avoids: [String] = [], budget: Int? = nil, place: [String] = [], audience: String? = nil, names: [String] = [],
        mode: String? = nil, skill: String = "down_for"
    ) {
        self.skill = skill
        fields = InterpretationLabel(text, day: day, from: from, to: to, wants: wants, avoids: avoids, budget: budget)
        self.place = place
        self.audience = audience
        self.names = names
        self.mode = mode
    }

    public var text: String { fields.text }
}

/// "Now" is the interpretation set's: Tuesday 2026-09-29 12:00 UTC.
public enum ChipSet {
    static let evening = 17...20
    static let lateEnd = 22...24

    public static let labels: [ChipLabel] = [
        // The mockup's sentence.
        .init("boba tonight with whoever's free, nothing far", day: .today, from: evening, to: lateEnd, wants: ["boba"], place: ["nothing far"], audience: "everyone"),
        .init("anyone down for tacos after 8?", from: 20...20, wants: ["tacos"], audience: "everyone"),
        .init("dinner tonight under $20 with Maya and Jake", day: .today, from: evening, to: lateEnd, wants: ["dinner"], budget: 20, names: ["Maya", "Jake"]),
        .init("who wants to play basketball this afternoon", day: .today, from: 12...13, to: 17...18, wants: ["basketball"], audience: "everyone"),
        .init("karaoke friday night with close friends", day: .friday, from: 17...21, to: lateEnd, wants: ["karaoke"], audience: "close"),
        .init("let's get pho, nothing far", wants: ["pho"], place: ["nothing far"]),
        .init("movie tonight anyone?", day: .today, from: evening, to: lateEnd, wants: ["movie"], audience: "everyone"),
        .init("ice cream with Priya after 9 tonight", day: .today, from: 21...21, to: lateEnd, wants: ["ice cream"], names: ["Priya"]),
        .init("pickup soccer at 5 today", day: .today, from: 17...17, wants: ["pickup soccer"]),
        .init("drinks later, $30 max, not too far", wants: ["drinks"], budget: 30, place: ["not too far"]),
        .init("coffee tomorrow morning near campus", day: .tomorrow, from: 6...9, to: 11...12, wants: ["coffee"], place: ["campus|near campus"]),
        .init("hike saturday with Sam and Alex, anything but the beach", day: .saturday, wants: ["hike"], avoids: ["beach|the beach"], names: ["Sam", "Alex"]),
        .init("cheap lunch today, under 10 bucks, no sushi", day: .today, from: 11...12, to: 13...14, wants: ["cheap lunch|lunch"], avoids: ["sushi"], budget: 10),
        .init("bowling or arcade tonight with everyone", day: .today, from: evening, to: lateEnd, wants: ["bowling", "arcade"], audience: "everyone"),
        .init("study session at the library between 2 and 5 tomorrow", day: .tomorrow, from: 14...14, to: 17...17, wants: ["study session"], place: ["library|the library"]),
        .init("ramen near downtown on thursday", day: .thursday, wants: ["ramen"], place: ["downtown|near downtown"]),
        .init("brunch sunday at 11 with Maya", day: .sunday, from: 11...11, wants: ["brunch"], names: ["Maya"]),
        .init("anyone free for a walk around the lake", wants: ["walk"], place: ["lake|the lake|around the lake"], audience: "everyone"),
        .init("tacos, $15 max, whoever's around", wants: ["tacos"], budget: 15, audience: "everyone"),
        .init("climbing wednesday evening with Jake", day: .wednesday, from: evening, to: lateEnd, wants: ["climbing"], names: ["Jake"]),
        // Core v2.1: send modes and leaving someone out (ADR 0020). Added
        // with their held-out items, before any measurement of them.
        .init("quietly see if anyone's up for boba tonight", day: .today, from: evening, to: lateEnd, wants: ["boba"], audience: "everyone", mode: "quietly"),
        .init("invite Maya and Jake to tacos friday", day: .friday, wants: ["tacos"], names: ["Maya", "Jake"], mode: "invite"),
        .init("boba tonight with everyone except Jake", day: .today, from: evening, to: lateEnd, wants: ["boba"], audience: "except", names: ["Jake"]),
        // Device test, 2026-10-02 (ADRs 0161 and 0212): a keyword chip is the
        // owner's words as typed, the whole phrase, in a span of the input.
        // The owner's two phrases and some like them, added with their
        // held-out items before any measurement of them.
        .init("movie night tonight in Elm Hall", day: .today, from: evening, to: lateEnd, wants: ["movie night"], place: ["Elm Hall"]),
        // Find a time only invites, so it shows no mode chip.
        .init("find a time invite for IKEA trip", wants: ["IKEA trip"], skill: "find_a_time"),
        .init("game night friday with Maya", day: .friday, from: 17...21, to: lateEnd, wants: ["game night"], names: ["Maya"]),
        .init("Costco run tomorrow afternoon", day: .tomorrow, from: 12...13, to: 17...18, wants: ["Costco run"]),
        .init("find a time for the Yosemite trip", wants: ["Yosemite trip"], skill: "find_a_time"),
    ]

    public static let heldOut: [ChipLabel] = [
        .init("who's up for bowling tonight", day: .today, from: evening, to: lateEnd, wants: ["bowling"], audience: "everyone"),
        .init("hot pot tonight with Sam, under $25", day: .today, from: evening, to: lateEnd, wants: ["hot pot"], budget: 25, names: ["Sam"]),
        .init("quick coffee before 3 today", day: .today, to: 15...15, wants: ["quick coffee|coffee"]),
        .init("beach tomorrow afternoon if anyone's around", day: .tomorrow, from: 12...13, to: 17...18, wants: ["beach"], audience: "everyone"),
        .init("dessert after 8 tonight, nothing far", day: .today, from: 20...20, to: lateEnd, wants: ["dessert"], place: ["nothing far"]),
        .init("pizza friday with close friends, no pineapple", day: .friday, wants: ["pizza"], avoids: ["pineapple"], audience: "close"),
        .init("board games saturday night with Priya and Maya", day: .saturday, from: 17...21, to: lateEnd, wants: ["board games"], names: ["Priya", "Maya"]),
        .init("run along the river at 7 tomorrow morning", day: .tomorrow, from: 7...7, wants: ["run"], place: ["river|the river|along the river"]),
        .init("cheap eats near campus, $8 max", wants: ["cheap eats"], budget: 8, place: ["campus|near campus"]),
        .init("tennis this afternoon, anyone?", day: .today, from: 12...13, to: 17...18, wants: ["tennis"], audience: "everyone"),
        .init("invite the climbing crew to bowling saturday", day: .saturday, wants: ["bowling"], names: ["climbing crew"], mode: "invite"),
        .init("dinner tonight with everyone but Sam", day: .today, from: evening, to: lateEnd, wants: ["dinner"], audience: "except", names: ["Sam"]),
        .init("trivia night tonight with Sam", day: .today, from: evening, to: lateEnd, wants: ["trivia night"], names: ["Sam"]),
        .init("find a time for our NYC trip", wants: ["NYC trip"], skill: "find_a_time"),
        .init("IHOP breakfast tomorrow morning", day: .tomorrow, from: 6...9, to: 11...12, wants: ["IHOP breakfast"]),
        .init("karaoke night saturday", day: .saturday, from: 17...21, to: lateEnd, wants: ["karaoke night"]),
        .init("find a time for the Tahoe ski trip", wants: ["Tahoe ski trip"], skill: "find_a_time"),
    ]
}
