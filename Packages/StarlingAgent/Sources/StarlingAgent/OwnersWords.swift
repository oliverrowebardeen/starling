import Foundation

/// Keyword chips in the owner's own words (ADRs 0161 and 0212, device test
/// of 2026-10-02): each chip is a phrase the owner typed, whole, in their
/// spelling, and no word is in two chips.
///
/// The message is read as phrases: runs of words between punctuation and
/// the words no activity is made of (articles, prepositions, times, people,
/// prices, rule words). "movie night tonight in Elm Hall" has two, "movie
/// night" and "Elm Hall". The model proposes; code takes the phrases the
/// proposal touches. A paraphrase ("Watch Movie") becomes the owner's
/// phrase around the word they share, a cut-off phrase ("trip") is the
/// whole one ("IKEA trip"), a stretch of the message ("dinner tonight with
/// Maya") is its first phrase, and a proposal with no word in the message
/// is dropped. The word lists are English only, like `Grounding`'s.
package struct OwnersWords {
    struct Token {
        /// As typed.
        let text: String
        let lower: String
        /// Punctuation or a line break before it ends a phrase.
        let breakBefore: Bool
    }

    /// A phrase picked for a chip.
    package struct Picked: Hashable, Sendable {
        /// As the owner typed it.
        package let text: String
        /// Right after "no", "not", or the like: something to avoid.
        package let negated: Bool
    }

    let tokens: [Token]
    /// The owner's phrases, by token index.
    let phrases: [ClosedRange<Int>]
    /// Words that are only a friend's name.
    let names: Set<String>
    /// Phrases already in a chip, by index into `phrases`.
    private(set) var used = Set<Int>()

    /// The longest phrase a chip can be.
    static let maxWords = 4

    package init(_ utterance: String, names: [String] = []) {
        let tokens = Self.tokenize(utterance)
        self.tokens = tokens
        self.names = Set(names.flatMap { Self.tokenize($0).map(\.lower) })
        var phrases: [ClosedRange<Int>] = []
        var start: Int?
        for index in tokens.indices {
            let continues = start != nil && !tokens[index].breakBefore
            // "night" and "day" end a phrase ("movie night", "beach day"),
            // never begin one ("tonight", "friday night").
            let tail = continues && Self.compoundTails.contains(tokens[index].lower)
            if !tail, Self.isStop(tokens[index].lower) {
                if let open = start { phrases.append(open...(index - 1)) }
                start = nil
            } else if !continues {
                if let open = start { phrases.append(open...(index - 1)) }
                start = index
            }
        }
        if let open = start { phrases.append(open...(tokens.count - 1)) }
        self.phrases = phrases.filter { $0.count <= Self.maxWords }
    }

    /// The owner's phrases for `proposal`: the first free phrase it
    /// touches that is not only a name and, with `many`, the phrases joined
    /// to it by "or", "and", or a comma ("bowling or arcade"). `place`
    /// allows a distance ("nothing far") for a place chip.
    package mutating func pick(_ proposal: String, place: Bool = false, many: Bool = false) -> [Picked] {
        let wanted = Self.tokenize(proposal).map(\.lower)
        guard !wanted.isEmpty else { return [] }
        let stems = Set(wanted.map(Grounding.stem))
        let words = Set(wanted)
        func touches(_ phrase: ClosedRange<Int>) -> Bool {
            phrase.contains { words.contains(tokens[$0].lower) || stems.contains(Grounding.stem(tokens[$0].lower)) }
        }
        let touched = phrases.indices.filter { !used.contains($0) && touches(phrases[$0]) && !isOnlyNames(phrases[$0]) }
        guard let first = touched.first else {
            guard place else { return [] }
            // "near campus": the place is what the owner is near.
            if !words.isDisjoint(with: Self.distanceWords), let near = nearPlace() {
                used.insert(near)
                return [picked(phrases[near])]
            }
            return distance(for: words).map { [$0] } ?? []
        }
        var chosen = [first]
        if many {
            for next in touched.dropFirst() where joined(phrases[chosen.last!], phrases[next]) { chosen.append(next) }
        }
        used.formUnion(chosen)
        return chosen.map { picked(phrases[$0]) }
    }

    private func picked(_ phrase: ClosedRange<Int>) -> Picked {
        let start = phrase.lowerBound
        let before = start > 0 && !tokens[start].breakBefore ? tokens[start - 1].lower : ""
        return Picked(text: phrase.map { tokens[$0].text }.joined(separator: " "), negated: Self.negations.contains(before))
    }

    private func isOnlyNames(_ phrase: ClosedRange<Int>) -> Bool {
        !names.isEmpty && phrase.allSatisfy { names.contains(tokens[$0].lower) }
    }

    /// Whether only "or", "and", or a comma stand between two phrases.
    private func joined(_ left: ClosedRange<Int>, _ right: ClosedRange<Int>) -> Bool {
        guard right.lowerBound > left.upperBound else { return false }
        return ((left.upperBound + 1)..<right.lowerBound).allSatisfy { Self.coordinators.contains(tokens[$0].lower) }
    }

    /// The free phrase right after "near" or "nearby", if any.
    private func nearPlace() -> Int? {
        phrases.indices.first { index in
            let start = phrases[index].lowerBound
            return !used.contains(index) && start > 0 && !tokens[start].breakBefore && ["near", "nearby"].contains(tokens[start - 1].lower)
        }
    }

    /// "nothing far", "not too far", "walking distance": a place chip for a
    /// distance the model put as "nearby" or "far".
    private func distance(for wanted: Set<String>) -> Picked? {
        guard !wanted.isDisjoint(with: Self.distanceWords) else { return nil }
        guard let at = tokens.indices.first(where: { Self.distanceWords.contains(tokens[$0].lower) }) else { return nil }
        var start = at
        while start > 0, !tokens[start].breakBefore, Self.qualifiers.contains(tokens[start - 1].lower) { start -= 1 }
        var end = at
        if end + 1 < tokens.count, !tokens[end + 1].breakBefore, tokens[end + 1].lower == "distance" { end += 1 }
        return Picked(text: (start...end).map { tokens[$0].text }.joined(separator: " "), negated: false)
    }

    static func isStop(_ word: String) -> Bool {
        if word.contains(where: \.isNumber) || word.hasPrefix("$") { return true }
        return stopWords.contains(word) || Grounding.ruleStems.contains(Grounding.stem(word))
            || SkillOutputMapping.timeWords.contains(word) || SkillOutputMapping.everyoneWords.contains(word)
    }

    static let compoundTails: Set<String> = ["night", "day"]
    static let negations: Set<String> = ["no", "not", "without", "except", "avoid", "never", "skip"]
    static let coordinators: Set<String> = ["or", "and", "&", "/"]
    /// Not "close": "close friends" says who, not where.
    static var distanceWords: Set<String> { SkillOutputMapping.distanceWords }
    static let qualifiers: Set<String> = ["not", "nothing", "too", "very", "no", "somewhere", "within"]

    /// Words no activity, place, or other keyword is made of.
    static let stopWords: Set<String> = [
        // articles, determiners, possessives
        "a", "an", "the", "this", "that", "these", "those", "some", "any", "our", "your", "his", "her", "their", "its", "next", "last", "each", "every",
        // prepositions and conjunctions
        "in", "at", "on", "for", "with", "to", "from", "by", "near", "around", "after", "before", "until", "till", "between", "of", "about",
        "into", "over", "under", "without", "but", "except", "like", "along", "across", "behind", "past", "within", "via", "and", "or", "nor",
        "so", "if", "then", "plus", "than", "as", "&", "/",
        // people and asking
        "we", "us", "they", "he", "she", "it", "who", "whose", "whom", "someone", "somebody", "everyone", "everybody", "anyone", "anybody",
        "whoever", "whoever's", "anyone's", "who's", "let's", "lets", "y'all", "yall",
        // the request itself
        "want", "wants", "wanna", "find", "invite", "inviting", "ask", "see", "go", "get", "grab", "have", "do", "play", "watch", "eat",
        "try", "hit", "is", "are", "was", "be", "can", "could", "should", "would", "will", "up", "down", "available", "quietly", "need",
        "looking", "look", "maybe", "please", "check", "meet", "hang", "out", "set", "pick", "choose", "skip",
        // degree words
        "too", "very", "really", "just", "only", "also", "even", "much", "more", "less", "pretty", "kinda", "sorta",
        // times and amounts
        "am", "pm", "noon", "midnight", "week", "weekend", "month", "year", "max", "min", "minutes", "hour", "hours",
        // distance
        "far", "nearby", "walking", "distance",
    ]

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var pendingBreak = false
        func flush() {
            guard !current.isEmpty else { return }
            // An apostrophe or dash at an edge belongs to no word.
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "'-’"))
            if !trimmed.isEmpty {
                tokens.append(Token(text: trimmed, lower: trimmed.lowercased().replacingOccurrences(of: "’", with: "'"), breakBefore: pendingBreak))
            }
            current = ""
            pendingBreak = false
        }
        for character in text {
            if character.isLetter || character.isNumber || character == "'" || character == "’" || character == "-" || character == "&" || character == "$" {
                current.append(character)
            } else {
                flush()
                if !character.isWhitespace || character.isNewline { pendingBreak = true }
            }
        }
        flush()
        return tokens
    }
}
