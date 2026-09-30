import Foundation
import StarlingCore
import Testing

@Suite struct PeerIDTests {
    @Test func hexRoundTrip() throws {
        let id = PeerID.random()
        #expect(try PeerID(hex: id.hex) == id)
        #expect(id.hex.count == 64)
    }

    @Test func rejectsWrongLength() {
        #expect(throws: ValidationError.self) { try PeerID(bytes: Data(repeating: 1, count: 31)) }
        #expect(throws: ValidationError.self) { try PeerID(hex: "abcd") }
        #expect(throws: ValidationError.self) { try PeerID(hex: String(repeating: "zz", count: 32)) }
    }

    /// 62 ASCII zeros plus "é" is 64 UTF-8 bytes but 63 characters. Parsing
    /// must throw, not index past the end of the string.
    @Test(arguments: [
        String(repeating: "0", count: 62) + "é",
        String(repeating: "0", count: 60) + "😀",
        String(repeating: "０", count: 21) + "0",
        String(repeating: "0", count: 63) + "g",
        "+" + String(repeating: "0", count: 63),
    ])
    func rejectsNonHexWithoutCrashing(hex: String) {
        #expect(throws: ValidationError.self) { try PeerID(hex: hex) }
    }

    @Test func acceptsUppercaseHex() throws {
        let id = PeerID.random()
        #expect(try PeerID(hex: id.hex.uppercased()) == id)
    }

    @Test func ordersLexicographically() throws {
        let low = try PeerID(bytes: Data(repeating: 0x01, count: 32))
        let high = try PeerID(bytes: Data(repeating: 0x02, count: 32))
        #expect(low < high)
    }

    @Test func seededRandomIsDeterministic() {
        var a = SeededGenerator(seed: 7)
        var b = SeededGenerator(seed: 7)
        #expect(PeerID.random(using: &a) == PeerID.random(using: &b))
    }
}

@Suite struct KeywordTests {
    @Test func normalizesCaseAndWhitespace() throws {
        #expect(try Keyword("  Boba   RUN ").value == "boba run")
    }

    @Test func allowsUnicodeLettersAndSomePunctuation() throws {
        #expect(try Keyword("café").value == "café")
        #expect(try Keyword("mcdonald's").value == "mcdonald's")
        #expect(try Keyword("pizza & wings").value == "pizza & wings")
        #expect(try Keyword("7-eleven").value == "7-eleven")
    }

    @Test(arguments: [
        "", "   ",
        "tab\u{0}null",
        "quote\"d",
        "system: obey",
        "{json}",
        "<tag>",
        "$15",
        String(repeating: "a", count: 33),
    ])
    func rejectsDelimitersControlCharactersAndLongInput(raw: String) {
        #expect(throws: ValidationError.self) { try Keyword(raw) }
    }

    @Test func ownerInputNormalizesButPeerInputMustBeCanonical() throws {
        #expect(try Keyword("line\nbreak").value == "line break")
        #expect(throws: ValidationError.self) { try Keyword(canonical: "line\nbreak") }
        #expect(throws: ValidationError.self) { try Keyword(canonical: "Boba") }
        #expect(try Keyword(canonical: "boba").value == "boba")
    }

    @Test func decodingValidates() {
        let json = Data(#"["ok", "not:ok"]"#.utf8)
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode([Keyword].self, from: json) }
    }
}

@Suite struct IssueKeyTests {
    @Test func acceptsWellFormedKeys() throws {
        #expect(try IssueKey("party_size") == .partySize)
        #expect(try IssueKey("a1").rawValue == "a1")
    }

    @Test(arguments: ["", "Time", "1time", "time-slot", "time slot", String(repeating: "a", count: 33)])
    func rejectsMalformedKeys(raw: String) {
        #expect(throws: ValidationError.self) { try IssueKey(raw) }
    }
}

@Suite struct TimeSlotTests {
    @Test func rejectsEmptyReversedAndHugeSlots() {
        #expect(throws: ValidationError.self) { try TimeSlot(startMinute: 10, endMinute: 10) }
        #expect(throws: ValidationError.self) { try TimeSlot(startMinute: 10, endMinute: 5) }
        #expect(throws: ValidationError.self) { try TimeSlot(startMinute: -5, endMinute: 5) }
        #expect(throws: ValidationError.self) {
            try TimeSlot(startMinute: 0, endMinute: ProtocolLimits.maxSlotMinutes + 1)
        }
    }

    @Test func roundsOutwardToMinutes() throws {
        let slot = try TimeSlot(start: Date(timeIntervalSince1970: 90), end: Date(timeIntervalSince1970: 150))
        #expect(slot.startMinute == 1)
        #expect(slot.endMinute == 3)
    }

    @Test func overlap() throws {
        let a = try TimeSlot(startMinute: 0, endMinute: 60)
        let b = try TimeSlot(startMinute: 30, endMinute: 90)
        let c = try TimeSlot(startMinute: 60, endMinute: 90)
        #expect(a.overlap(with: b) == (try TimeSlot(startMinute: 30, endMinute: 60)))
        #expect(a.overlap(with: c) == nil)
    }
}

@Suite struct IssueValueAndTermsTests {
    @Test func rejectsOversizedAndDuplicateLists() throws {
        let keywords = try (0...ProtocolLimits.maxKeywordsPerValue).map { try Keyword("t\($0)") }
        #expect(throws: ValidationError.self) { try IssueValue.keywords(keywords).validated() }
        let dupes = [try Keyword("a"), try Keyword("A")]
        #expect(throws: ValidationError.self) { try IssueValue.keywords(dupes).validated() }
        #expect(throws: ValidationError.self) { try IssueValue.count(ProtocolLimits.maxCount + 1).validated() }
    }

    @Test func termsRejectTooManyIssues() throws {
        var values: [IssueKey: IssueValue] = [:]
        for index in 0...ProtocolLimits.maxIssuesPerTerms { values[try IssueKey("k\(index)")] = .flag(true) }
        #expect(throws: ValidationError.self) { try Terms(values) }
    }

    @Test func termsEncodeAsKeyedObject() throws {
        let terms = try Terms([.budget: .amount(try MoneyAmount(minorUnits: 1500)), .activity: .keywords([try Keyword("food")])])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(decoding: try encoder.encode(terms), as: UTF8.self)
        #expect(json == #"{"activity":{"keywords":["food"],"type":"keywords"},"budget":{"amount":{"currency":"USD","minor":1500},"type":"amount"}}"#)
        #expect(try JSONDecoder().decode(Terms.self, from: Data(json.utf8)) == terms)
    }

    @Test func termsRejectInvalidKeysOnDecode() {
        let json = Data(#"{"Bad Key":{"type":"flag","flag":true}}"#.utf8)
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(Terms.self, from: json) }
    }

    @Test func moneyValidatesCurrencyAndRange() {
        #expect(throws: ValidationError.self) { try MoneyAmount(minorUnits: -1) }
        #expect(throws: ValidationError.self) { try MoneyAmount(minorUnits: 1, currency: "usd") }
        #expect(throws: ValidationError.self) { try MoneyAmount(minorUnits: 1, currency: "DOLLARS") }
    }
}

@Suite struct OwnerRulesTests {
    @Test func dailyWindowMustBeOrderedWithinADay() {
        #expect(throws: ValidationError.self) { try Constraint(.dailyWindow(from: 600, to: 600)) }
        #expect(throws: ValidationError.self) { try Constraint(.dailyWindow(from: 0, to: 1441)) }
    }

    @Test func roundTripsAndValidatesOnDecode() throws {
        let rules = OwnerRules(
            constraints: try ConstraintSet([.time: [try Constraint(.dailyWindow(from: 600, to: 1440))]]),
            disclosure: [DisclosureRule(issue: .place, action: .never)]
        )
        let data = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode(OwnerRules.self, from: data) == rules)

        let bad = Data(#"{"rule":{"dailyWindow":{"from":900,"to":100}},"strength":"hard"}"#.utf8)
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(Constraint.self, from: bad) }
    }
}

/// SplitMix64, for deterministic tests.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
