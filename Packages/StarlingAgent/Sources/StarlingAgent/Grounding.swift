import Foundation

/// Checks interpreted rules against the owner's own words: drops what the
/// words do not support and puts stated hours on a 24-hour clock. The model
/// proposes; code checks (ARCHITECTURE rule 6), here applied to
/// interpretation.
///
/// No check invents a value, and the owner reviews the result either way
/// (brief 2.5). The word lists are English only; ADR 0161 records what that
/// costs.
package enum Grounding {
    package static func check(_ raw: RawRules, against utterance: String) -> RawRules {
        let words = Self.words(utterance)
        let stems = Set(words.map(stem))
        var checked = raw
        if let day = raw.day, !isNamed(day, in: words) { checked.day = nil }
        if let part = raw.partOfDay, words.allSatisfy({ !(partWords[part] ?? []).contains($0) }) { checked.partOfDay = nil }
        (checked.earliestHour, checked.latestHour) = hours(checked, words: words)
        checked.wants = raw.wants.filter { isActivity($0, stems: stems) }
        checked.avoids = raw.avoids.map(dropLeadingNegation).filter { isActivity($0, stems: stems) }
        if let dollars = raw.maxDollars, !numbers(in: words).contains(dollars) {
            checked.maxDollars = nil
        }
        let asksPrivacy = !stems.isDisjoint(with: privacyStems)
        checked.neverShare = raw.neverShare.filter { field in
            asksPrivacy && !stems.isDisjoint(with: fieldStems[field] ?? [])
        }
        return checked
    }

    /// A day counts only if the message names it: models default to "today"
    /// when the owner named no day at all.
    static func isNamed(_ day: RawRules.Day, in words: [String]) -> Bool {
        let named: Set<String>
        switch day {
        case .relative(0): named = ["today", "tonight", "now", "this"]
        case .relative(1): named = ["tomorrow", "tmrw", "tmr"]
        case .relative: return false
        case .weekday(let weekday):
            guard (1...7).contains(weekday) else { return false }
            let names = [["sunday", "sun"], ["monday", "mon"], ["tuesday", "tue", "tues"], ["wednesday", "wed"], ["thursday", "thu", "thur", "thurs"], ["friday", "fri"], ["saturday", "sat"]][weekday - 1]
            named = Set(names + (weekday == 1 || weekday == 7 ? ["weekend"] : []))
        }
        return words.contains { named.contains($0) }
    }

    /// Words that name each part of the day. "Dinner" is left out on
    /// purpose: "want dinner" names an activity, not a time.
    static let partWords: [RawRules.PartOfDay: Set<String>] = [
        .morning: ["morning", "breakfast", "am"],
        .lunch: ["lunch", "noon", "midday", "brunch"],
        .afternoon: ["afternoon"],
        .evening: ["evening", "tonight", "night"],
    ]

    /// Keeps only hours the message states, then puts them on a 24-hour
    /// clock. The small model fills hours nobody said (23 as "no end") and
    /// copies "7" from "at 7"; people making plans with friends mean the
    /// afternoon or evening unless they say "am" or "morning".
    static func hours(_ raw: RawRules, words: [String]) -> (Int?, Int?) {
        let stated = numbers(in: words)
        let saysNoon = words.contains("noon")
        let saysMidnight = words.contains("midnight")
        let saysAM = words.contains { $0 == "am" || meridiem($0) == "am" }
        let saysPM = words.contains { $0 == "pm" || meridiem($0) == "pm" }
        func grounded(_ hour: Int?) -> Int? {
            guard let hour else { return nil }
            if stated.contains(hour) { return hour }
            // 21 is stated as "9" or "9pm", but not by "9am" alone.
            if hour > 12, stated.contains(hour - 12), !(saysAM && !saysPM) { return hour }
            if hour == 12 && saysNoon { return hour }
            if (hour == 0 || hour == 24) && saysMidnight { return hour }
            return nil
        }
        var earliest = grounded(raw.earliestHour)
        var latest = grounded(raw.latestHour)
        // A single point in time ("at 3", "after 9") is a start, not a window.
        if let from = earliest, from == latest { latest = nil }
        let later = saysPM || raw.partOfDay == .afternoon || raw.partOfDay == .evening
        func clock(_ hour: Int?) -> Int? {
            guard let hour, (1...11).contains(hour) else { return hour }
            if saysAM && !saysPM { return hour }
            if hour <= 6 || later { return hour + 12 }
            return hour
        }
        earliest = clock(earliest)
        latest = clock(latest)
        // "between 5 and 7": the end is the same half of the day as the start.
        if let from = earliest, let to = latest, to <= from, to + 12 > from, to + 12 <= 24 { latest = to + 12 }
        return (earliest, latest)
    }

    /// "am" or "pm" when `word` is a number glued to one, like "10pm".
    static func meridiem(_ word: String) -> String? {
        guard word.count > 2, word.dropLast(2).allSatisfy(\.isNumber) else { return nil }
        let suffix = String(word.suffix(2))
        return suffix == "am" || suffix == "pm" ? suffix : nil
    }

    /// "no seafood" names seafood; the negation is what made it an avoid.
    static func dropLeadingNegation(_ phrase: String) -> String {
        var parts = phrase.split(separator: " ")
        while let first = parts.first, ["no", "not", "never", "avoid", "without"].contains(first.lowercased()) { parts.removeFirst() }
        return parts.joined(separator: " ")
    }

    /// An activity must share a word with the owner's message (so it was not
    /// invented) and must not be a fragment of a rule ("not far", "under 8
    /// bucks", "share schedule", "surprise me").
    static func isActivity(_ phrase: String, stems: Set<String>) -> Bool {
        let own = words(phrase).map(stem)
        guard !own.isEmpty, own.allSatisfy({ !ruleStems.contains($0) }) else { return false }
        guard !own.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return false }
        return own.contains { stems.contains($0) }
    }

    /// Words that belong to times, prices, sharing, negation, or the people
    /// involved. None of them names something to do or eat.
    static let ruleStems: Set<String> = Set([
        "no", "not", "never", "don", "dont", "avoid", "but", "without",
        "none", "nothing", "anything", "whatever", "something", "everything", "activity",
        "under", "over", "max", "maximum", "most", "least", "budget", "dollar", "dollars", "buck", "bucks",
        "spend", "spending", "price", "cost",
        "share", "tell", "private", "secret", "know", "hide",
        "plan", "plans", "free", "until", "before", "after", "later", "earlier", "time", "day", "schedule",
        "today", "tonight", "tomorrow", "morning", "afternoon", "evening", "night",
        "far", "near", "close", "location", "where", "works", "work", "fine",
        "i", "im", "me", "my", "you", "people", "them", "anyone",
    ].map(stem))

    static let privacyStems: Set<String> = Set(["share", "tell", "private", "secret", "know", "hide", "reveal", "disclose"].map(stem))

    static let fieldStems: [RawRules.Shareable: Set<String>] = [
        .location: Set(["where", "location", "address", "whereabouts"].map(stem)),
        .schedule: Set(["schedule", "when", "calendar", "availability", "busy"].map(stem)),
        .budget: Set(["budget", "spend", "money", "price", "cost", "afford", "much"].map(stem)),
    ]

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// A crude suffix strip, enough to equate "hiking" with "hike" and
    /// "tacos" with "taco". Not a real stemmer.
    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s", "e"] where word.count > suffix.count + 2 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count))
        }
        return word
    }

    /// Every whole number the message states, as digits ("$15") or words
    /// ("twenty", "twenty five").
    static func numbers(in words: [String]) -> Set<Int> {
        var found = Set<Int>()
        var index = 0
        while index < words.count {
            let word = words[index]
            if let value = Int(word) {
                found.insert(value)
            } else if meridiem(word) != nil, let value = Int(word.dropLast(2)) {
                found.insert(value)
            } else if let tens = tensWords[word] {
                if index + 1 < words.count, let ones = unitWords[words[index + 1]], (1...9).contains(ones) {
                    found.insert(tens + ones)
                    index += 1
                } else {
                    found.insert(tens)
                }
            } else if let value = unitWords[word] {
                found.insert(value)
            } else if word == "hundred" {
                found.insert(100)
            }
            index += 1
        }
        return found
    }

    private static let unitWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    private static let tensWords: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
}
