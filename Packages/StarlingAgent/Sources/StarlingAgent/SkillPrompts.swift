import Foundation
import StarlingCore

// Prompts for SkillModel (ADR 0016). Pure and deterministic, so tests pin
// exactly what the model sees. Routing and chips see only the owner's own
// words; a proposal sentence sees typed facts and the owner's nicknames for
// friends. No peer text, and no venue name, ever reaches these prompts.

extension PromptRenderer {
    package static let routeInstructions = """
        Choose the skill that does what the owner asks. Each skill says what it is for. \
        When the owner names something to do or eat soon, choose the skill that checks who is up for it. \
        Choose a skill that agrees on where or when only if the owner asks where, or asks when for later. \
        Choose none if the message does not ask to plan something with friends.
        """

    package static let intentInstructions = """
        Read what the owner wants from their message. Fill a field only from the owner's own words. \
        Activities are short lowercase things to do or eat, never days, times, prices, places, or people. \
        Names are only names of people, never activities, places, or words like whoever or anyone. \
        Audience is everyone when the owner asks anyone, whoever, or everyone.
        """

    package static let proposalInstructions = """
        Write one short, friendly sentence telling the owner about a plan with friends, then ask if it works. \
        Use only the facts given. Name every friend. Use the activity exactly as given. \
        If a time is given, write {time} where the time goes; it reads like "tonight at 8:30 PM". \
        If a place is given, write {place} where the place goes. No dashes.
        """

    /// The skills that can run, by id, described from their own data: name,
    /// summary, what their building block does, and what each slot looks
    /// for. Nothing here is written per skill, so a new skill routes from
    /// its descriptor alone (ADR 0212).
    package static func route(_ utterance: OwnerUtterance, skills: [SkillDescriptor]) -> String {
        var lines = ["Skills:"]
        for skill in skills {
            let reads = skill.intent.slots.map { "\($0.hint)\($0.required ? "" : " (optional)")" }
            lines.append("- \(skill.id): \(skill.wording.name) \(skill.wording.summary). \(purpose(of: skill.buildingBlock)) Reads: \(reads.joined(separator: "; ")).")
        }
        lines.append("Owner: \(utterance.text)")
        return lines.joined(separator: "\n")
    }

    /// What each building block does, in plain words (brief 2.7).
    package static func purpose(of block: BuildingBlock) -> String {
        switch block {
        case .mutualReveal: "Checks which friends are up for doing something now or soon."
        case .privateQuery: "Asks friends' agents a question, such as when they are free."
        case .privateAggregation: "Combines everyone's preferences into one choice, such as a venue."
        case .negotiationWithPrivateLimits: "Agrees on terms within private limits."
        case .matchedExchange: "Swaps items with the people they belong to."
        }
    }

    package static func intent(_ utterance: OwnerUtterance) -> String {
        "Owner: \(utterance.text)"
    }

    /// Typed facts only. The place and the time are never written out: the
    /// model writes placeholders and code fills them in, so the sentence
    /// cannot get the day or the hour wrong (review of PR #56, finding 7)
    /// and a venue name never reaches the model (ADR 0012).
    package static func proposal(_ facts: ProposalFacts, time: String?) -> String {
        var lines: [String] = []
        lines.append("Friends: " + (facts.friendNames.isEmpty ? "none" : facts.friendNames.joined(separator: ", ")))
        if let activity = facts.activity { lines.append("Activity: \(activity.value)") }
        if time != nil { lines.append("Time: \(ProposalSentence.timePlaceholder)") }
        if facts.place != nil { lines.append("Place: \(ProposalSentence.placeholder)") }
        return lines.joined(separator: "\n")
    }

    /// "tonight at 8:30 PM", "tomorrow at 9 AM", "Saturday at 2 PM".
    package static func spokenTime(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let clock = (hour % 12 == 0 ? "12" : "\(hour % 12)") + (minute == 0 ? "" : String(format: ":%02d", minute)) + (hour < 12 ? " AM" : " PM")
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let day: String = switch days {
        case 0: hour >= 17 ? "tonight" : "today"
        case 1: "tomorrow"
        default: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][calendar.component(.weekday, from: date) - 1]
        }
        return "\(day) at \(clock)"
    }
}

/// Code's checks on the model's skill outputs (ARCHITECTURE rule 6). The
/// model proposes; these keep only what the owner's words or the typed
/// facts support.
package enum SkillOutputMapping {
    /// Days and parts of days: never an activity ("brunch sunday at 11"
    /// once came back wanting "sunday").
    static let timeWords: Set<String> = [
        "today", "tonight", "tomorrow", "weekend", "morning", "afternoon", "evening", "night", "now", "later",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]
    /// Words that make a distance chip ("nothing far") stand for "nearby",
    /// the word the place slot's hint uses. Not "close" or "around": "close
    /// friends" and "whoever's around" say who, not where.
    static let distanceWords: Set<String> = ["far", "near", "nearby", "walking"]

    /// Words that ask everyone, or close friends, or no one in particular.
    static let everyoneWords: Set<String> = ["everyone", "everybody", "anyone", "anybody", "whoever", "whoevers", "all", "friends", "people", "folks", "crew", "group"]
    static let defaultExpiry: TimeInterval = 3 * 3600

    /// The chips for one skill, grounded in the owner's words (ADR 0161):
    /// time, activity, and budget through `Grounding`, other slots' words
    /// only if the message uses them, and the audience and names only if
    /// the message says so. Nothing is invented; the owner edits the rest.
    package static func parsed(_ raw: RawIntent, utterance: String, skill: SkillDescriptor, now: Date, timeZone: TimeZone) throws -> ParsedIntent {
        let slots = Set(skill.intent.slots.map(\.issue))
        var rules = raw.rules
        // Interpretation of a request never sets sharing: privacy topics do
        // that, globally (ADR 0014).
        rules.neverShare = []
        // A day or a group of people is never something to do.
        rules.wants = rules.wants.filter { want in
            let own = Set(Grounding.words(want))
            return !own.isEmpty && own.isDisjoint(with: timeWords) && own.isDisjoint(with: everyoneWords)
        }
        let checked = Grounding.check(rules, against: utterance)
        let context = InterpretationContext(now: now, timeZone: timeZone, issues: skill.intent.slots.map(\.issue))
        var constraints = try OutputMapping.rules(checked, context: context).constraints.constraints.filter { slots.contains($0.key) }

        let words = Grounding.words(utterance)
        let stems = Set(words.map(Grounding.stem))
        for (issue, phrases) in raw.extras where slots.contains(issue) {
            let saysDistance = !Set(words).isDisjoint(with: distanceWords)
            let kept = keywords(phrases.filter { phrase in
                let own = Grounding.words(phrase).map(Grounding.stem)
                if saysDistance, own == ["nearby"] { return true }
                // "close friends" names an audience, not a place.
                guard Set(Grounding.words(phrase)).isDisjoint(with: everyoneWords) else { return false }
                return !own.isEmpty && own.contains(where: stems.contains) && !own.allSatisfy { $0.allSatisfy(\.isNumber) }
            })
            if !kept.isEmpty { constraints[issue] = [try Constraint(.prefers(liked: kept, avoided: []), strength: .soft)] }
        }

        var audience: Audience?
        var names: [String] = []
        if skill.intent.asksForAudience {
            // A name is not something the owner wants to do or a place.
            let taken = Set((raw.rules.wants + raw.rules.avoids + raw.extras.values.flatMap { $0 }).flatMap { Grounding.words($0) })
            names = grounded(names: raw.names, in: utterance).filter { Set(Grounding.words($0)).isDisjoint(with: taken) }
            if names.isEmpty {
                switch raw.audience {
                case .everyone where !Set(words).isDisjoint(with: everyoneWords): audience = .allFriends
                case .closeFriends where words.contains("close"): audience = .closeFriends
                default: break
                }
            }
        }

        var expiresAt: Timestamp?
        if skill.intent.asksForExpiry {
            var end = now.addingTimeInterval(defaultExpiry)
            for constraint in constraints[.time] ?? [] {
                if case .within(let windows) = constraint.rule, let last = windows.map(\.end).max(), last > now { end = last }
            }
            expiresAt = Timestamp(end)
        }
        return ParsedIntent(constraints: try ConstraintSet(constraints), audience: audience, expiresAt: expiresAt, mentionedNames: names)
    }

    /// Names that appear in the message as written, in the message's own
    /// spelling, at most four. A word for a group ("friends") is not a name.
    static func grounded(names: [String], in utterance: String) -> [String] {
        let original = utterance.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" }).map(String.init)
        var found: [String] = []
        for name in names {
            let parts = name.split(separator: " ").map(String.init)
            guard (1...3).contains(parts.count) else { continue }
            for start in original.indices where start + parts.count <= original.count {
                let candidate = Array(original[start..<start + parts.count])
                guard zip(candidate, parts).allSatisfy({ $0.lowercased() == $1.lowercased() }) else { continue }
                let spelled = candidate.joined(separator: " ")
                let lower = spelled.lowercased()
                let groupWord = !Set(Grounding.words(lower)).isDisjoint(with: everyoneWords)
                if !groupWord, !Grounding.ruleStems.contains(Grounding.stem(lower)),
                   !found.contains(where: { $0.lowercased() == lower }) {
                    found.append(spelled)
                }
                break
            }
        }
        return Array(found.prefix(IntentGenerationSchema.maxNames))
    }

    private static func keywords(_ strings: [String]) -> [Keyword] {
        var seen = Set<Keyword>()
        return strings.compactMap { try? Keyword($0) }.filter { seen.insert($0).inserted }
    }

    /// Accepts the model's sentence only if it says what the facts say and
    /// nothing more: every friend, the activity, each placeholder exactly
    /// once when its fact is given and never otherwise, and no time of its
    /// own (no digits, day, or part of day). Code then fills in the time and
    /// the place. Dashes become commas (owner norm). Anything else throws,
    /// and the caller shows the skill's template instead.
    package static func sentence(_ text: String, facts: ProposalFacts, time: String?) throws -> String {
        var sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for dash in [" \u{2014} ", "\u{2014}", " \u{2013} ", "\u{2013}"] { sentence = sentence.replacingOccurrences(of: dash, with: ", ") }
        func reject(_ why: String) -> AgentModelError { .invalidOutput("proposal sentence: \(why)") }
        guard !sentence.isEmpty, sentence.count <= ProposalSentence.maxCharacters, !sentence.contains(where: \.isNewline) else { throw reject("length") }
        let lower = sentence.lowercased()
        for name in facts.friendNames where !lower.contains(name.lowercased()) { throw reject("missing a friend") }
        if let activity = facts.activity {
            guard lower.contains(activity.value) else { throw reject("missing the activity") }
        } else if Grounding.words(lower).contains("down") {
            // Never "down" without an activity (ADR 0017).
            throw reject("down without an activity")
        }
        guard !sentence.contains(where: \.isNumber) else { throw reject("a number of its own") }
        let own = Set(Grounding.words(lower))
        guard own.isDisjoint(with: timeWords), own.isDisjoint(with: ["am", "pm", "noon", "midnight", "o'clock"]) else {
            throw reject("a time of its own")
        }
        func count(_ mark: String) -> Int { sentence.components(separatedBy: mark).count - 1 }
        guard count(ProposalSentence.timePlaceholder) == (time == nil ? 0 : 1) else { throw reject("time placeholder") }
        guard count(ProposalSentence.placeholder) == (facts.place == nil ? 0 : 1) else { throw reject("place placeholder") }
        if let time {
            // The phrase brings its own preposition ("tonight at 8:30 PM").
            for lead in ["at ", "At ", "on ", "On "] { sentence = sentence.replacingOccurrences(of: lead + ProposalSentence.timePlaceholder, with: ProposalSentence.timePlaceholder) }
            sentence = sentence.replacingOccurrences(of: ProposalSentence.timePlaceholder, with: time)
        }
        if let place = facts.place { sentence = sentence.replacingOccurrences(of: ProposalSentence.placeholder, with: place.rawValue) }
        // Anything left in braces was not a placeholder we gave.
        guard !sentence.contains("{"), !sentence.contains("}") else { throw reject("an unknown placeholder") }
        return sentence
    }
}
