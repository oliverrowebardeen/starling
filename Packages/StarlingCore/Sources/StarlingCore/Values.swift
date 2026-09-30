import Foundation

// MARK: - Keyword

/// A short, normalized label such as "boba run" or "vegetarian".
///
/// Keywords are the only human-language text a peer can send, and they may reach a
/// model prompt through fuzzy matching. They are therefore lowercased, limited
/// to `ProtocolLimits.maxKeywordCharacters`, and restricted to letters, digits,
/// spaces, and `- ' &`. No newlines, quotes, colons, or brackets.
public struct Keyword: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let value: String

    /// Normalizes the owner's input (collapses whitespace, lowercases), then
    /// validates. For data from a peer, use `init(canonical:)`.
    public init(_ raw: String) throws {
        let collapsed = raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        guard !collapsed.isEmpty else { throw ValidationError("Keyword", "empty") }
        guard collapsed.count <= ProtocolLimits.maxKeywordCharacters else {
            throw ValidationError("Keyword", "longer than \(ProtocolLimits.maxKeywordCharacters) characters")
        }
        for scalar in collapsed.unicodeScalars where !Keyword.isAllowed(scalar) {
            throw ValidationError("Keyword", "character U+\(String(scalar.value, radix: 16, uppercase: true)) not allowed")
        }
        value = collapsed
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " || scalar == "-" || scalar == "'" || scalar == "&" { return true }
        let properties = scalar.properties
        return properties.isAlphabetic || properties.numericType == .decimal
    }

    public var description: String { value }
    public static func < (lhs: Keyword, rhs: Keyword) -> Bool { lhs.value < rhs.value }
}

extension Keyword {
    /// Accepts only input that is already in canonical form, so one keyword
    /// has exactly one wire encoding (PSI hashes depend on it). Used when
    /// decoding peer data.
    public init(canonical: String) throws {
        try self.init(canonical)
        guard value == canonical else { throw ValidationError("Keyword", "not in canonical form") }
    }
}

extension Keyword: Codable {
    public init(from decoder: any Decoder) throws { try self.init(canonical: decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

// MARK: - IssueKey

/// Names one negotiable issue, such as `time` or `budget`.
/// Format: a lowercase ASCII letter, then up to 31 of `a-z 0-9 _`.
public struct IssueKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let scalars = Array(rawValue.unicodeScalars)
        guard let first = scalars.first, ("a"..."z").contains(first) else {
            throw ValidationError("IssueKey", "must start with a lowercase letter")
        }
        guard scalars.count <= ProtocolLimits.maxIssueKeyCharacters else {
            throw ValidationError("IssueKey", "too long")
        }
        guard scalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }) else {
            throw ValidationError("IssueKey", "only a-z, 0-9 and _ allowed")
        }
        self.rawValue = rawValue
    }

    private init(known: String) { rawValue = known }

    public static let time = IssueKey(known: "time")
    public static let activity = IssueKey(known: "activity")
    public static let budget = IssueKey(known: "budget")
    public static let place = IssueKey(known: "place")
    public static let diet = IssueKey(known: "diet")
    public static let partySize = IssueKey(known: "party_size")
    /// "down" or "maybe" as a keyword, exchanged only in an acceptance so a
    /// "maybe" is revealed only when interest is mutual (ADR 0120, v1.1).
    public static let downLevel = IssueKey(known: "down_level")

    public var description: String { rawValue }
    public static func < (lhs: IssueKey, rhs: IssueKey) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension IssueKey: Codable, CodingKeyRepresentable {
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var codingKey: any CodingKey { IssueCodingKey(stringValue: rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        guard let key = try? IssueKey(codingKey.stringValue) else { return nil }
        self = key
    }

    private struct IssueCodingKey: CodingKey {
        let stringValue: String
        init(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }
}

// MARK: - TimeSlot

/// A half-open interval `[start, end)` with minute resolution, in UTC.
/// Minute resolution keeps slots canonical, which PSI needs.
public struct TimeSlot: Hashable, Comparable, Sendable {
    public let startMinute: Int64
    public let endMinute: Int64

    public init(startMinute: Int64, endMinute: Int64) throws {
        guard startMinute >= 0 else { throw ValidationError("TimeSlot", "starts before 1970") }
        guard endMinute > startMinute else { throw ValidationError("TimeSlot", "end must be after start") }
        guard endMinute - startMinute <= ProtocolLimits.maxSlotMinutes else {
            throw ValidationError("TimeSlot", "longer than \(ProtocolLimits.maxSlotMinutes) minutes")
        }
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    /// Rounds `start` down and `end` up to whole minutes.
    public init(start: Date, end: Date) throws {
        try self.init(
            startMinute: Int64((start.timeIntervalSince1970 / 60).rounded(.down)),
            endMinute: Int64((end.timeIntervalSince1970 / 60).rounded(.up))
        )
    }

    public var start: Date { Date(timeIntervalSince1970: Double(startMinute) * 60) }
    public var end: Date { Date(timeIntervalSince1970: Double(endMinute) * 60) }
    public var durationMinutes: Int64 { endMinute - startMinute }

    public func overlap(with other: TimeSlot) -> TimeSlot? {
        let lower = max(startMinute, other.startMinute)
        let upper = min(endMinute, other.endMinute)
        return upper > lower ? try? TimeSlot(startMinute: lower, endMinute: upper) : nil
    }

    public static func < (lhs: TimeSlot, rhs: TimeSlot) -> Bool {
        (lhs.startMinute, lhs.endMinute) < (rhs.startMinute, rhs.endMinute)
    }
}

extension TimeSlot: Codable {
    private enum CodingKeys: String, CodingKey { case start, end }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            startMinute: container.decode(Int64.self, forKey: .start),
            endMinute: container.decode(Int64.self, forKey: .end)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startMinute, forKey: .start)
        try container.encode(endMinute, forKey: .end)
    }
}

// MARK: - MoneyAmount

/// An amount in minor units (cents for USD) with an ISO 4217 currency code.
public struct MoneyAmount: Hashable, Sendable {
    public let minorUnits: Int64
    public let currency: String

    public init(minorUnits: Int64, currency: String = "USD") throws {
        guard (0...ProtocolLimits.maxMoneyMinorUnits).contains(minorUnits) else {
            throw ValidationError("MoneyAmount", "out of range")
        }
        guard currency.unicodeScalars.count == 3, currency.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else {
            throw ValidationError("MoneyAmount", "currency must be three uppercase letters")
        }
        self.minorUnits = minorUnits
        self.currency = currency
    }
}

extension MoneyAmount: Codable {
    private enum CodingKeys: String, CodingKey { case minorUnits = "minor", currency }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            minorUnits: container.decode(Int64.self, forKey: .minorUnits),
            currency: container.decode(String.self, forKey: .currency)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(minorUnits, forKey: .minorUnits)
        try container.encode(currency, forKey: .currency)
    }
}

// MARK: - IssueValue

/// The value of one issue in an offer, query, or answer.
public enum IssueValue: Hashable, Sendable {
    case slots([TimeSlot])
    case keywords([Keyword])
    case amount(MoneyAmount)
    case flag(Bool)
    case count(Int)

    /// Validates list sizes and ranges. Called by every initializer path that
    /// accepts peer data.
    public func validated() throws -> IssueValue {
        switch self {
        case .slots(let slots):
            guard slots.count <= ProtocolLimits.maxSlotsPerValue else {
                throw ValidationError("IssueValue.slots", "more than \(ProtocolLimits.maxSlotsPerValue) slots")
            }
        case .keywords(let keywords):
            guard keywords.count <= ProtocolLimits.maxKeywordsPerValue else {
                throw ValidationError("IssueValue.keywords", "more than \(ProtocolLimits.maxKeywordsPerValue) keywords")
            }
            guard Set(keywords).count == keywords.count else { throw ValidationError("IssueValue.keywords", "duplicate keywords") }
        case .count(let count):
            guard (0...ProtocolLimits.maxCount).contains(count) else {
                throw ValidationError("IssueValue.count", "out of range")
            }
        case .amount, .flag:
            break
        }
        return self
    }
}

extension IssueValue: Codable {
    private enum CodingKeys: String, CodingKey { case type, slots, keywords, amount, flag, count }
    private enum Kind: String, Codable { case slots, keywords, amount, flag, count }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value: IssueValue
        switch try container.decode(Kind.self, forKey: .type) {
        case .slots: value = .slots(try container.decode([TimeSlot].self, forKey: .slots))
        case .keywords: value = .keywords(try container.decode([Keyword].self, forKey: .keywords))
        case .amount: value = .amount(try container.decode(MoneyAmount.self, forKey: .amount))
        case .flag: value = .flag(try container.decode(Bool.self, forKey: .flag))
        case .count: value = .count(try container.decode(Int.self, forKey: .count))
        }
        self = try value.validated()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch try validated() {
        case .slots(let slots):
            try container.encode(Kind.slots, forKey: .type)
            try container.encode(slots, forKey: .slots)
        case .keywords(let keywords):
            try container.encode(Kind.keywords, forKey: .type)
            try container.encode(keywords, forKey: .keywords)
        case .amount(let amount):
            try container.encode(Kind.amount, forKey: .type)
            try container.encode(amount, forKey: .amount)
        case .flag(let flag):
            try container.encode(Kind.flag, forKey: .type)
            try container.encode(flag, forKey: .flag)
        case .count(let count):
            try container.encode(Kind.count, forKey: .type)
            try container.encode(count, forKey: .count)
        }
    }
}

// MARK: - Terms

/// A set of issue values: the content of an offer or an acceptance.
public struct Terms: Hashable, Sendable {
    public let values: [IssueKey: IssueValue]

    public init(_ values: [IssueKey: IssueValue]) throws {
        guard values.count <= ProtocolLimits.maxIssuesPerTerms else {
            throw ValidationError("Terms", "more than \(ProtocolLimits.maxIssuesPerTerms) issues")
        }
        self.values = try values.mapValues { try $0.validated() }
    }

    public static let empty = try! Terms([:])

    public subscript(key: IssueKey) -> IssueValue? { values[key] }
}

extension Terms: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode([IssueKey: IssueValue].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}
