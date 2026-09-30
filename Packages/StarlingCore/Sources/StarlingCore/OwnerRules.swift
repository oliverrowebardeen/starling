import Foundation

// These types describe the owner's private rules. They are Codable for local
// storage only. No `MessageBody` case can carry them, so the type system keeps
// them on the device.

/// One private limit on an issue, such as "at most $15" or "not before 10:00".
public struct Constraint: Hashable, Sendable {
    public enum Rule: Hashable, Sendable, Codable {
        /// Acceptable absolute time windows ("free tonight 7 to 11").
        case within([TimeSlot])
        /// A daily local-time window in minutes after midnight, `0...1440`
        /// ("no plans before 10" is `dailyWindow(from: 600, to: 1440)`).
        case dailyWindow(from: Int, to: Int)
        /// Liked and avoided keywords ("want food", "no sushi").
        case prefers(liked: [Keyword], avoided: [Keyword])
        case atMost(MoneyAmount)
        case atLeast(MoneyAmount)
        case mustBe(Bool)
        case countBetween(min: Int, max: Int)
    }

    public enum Strength: String, Hashable, Sendable, Codable {
        /// A walk-away point. Never relaxed by negotiation.
        case hard
        /// A preference the agent may trade away.
        case soft
    }

    public let rule: Rule
    public let strength: Strength

    public init(_ rule: Rule, strength: Strength = .hard) throws {
        switch rule {
        case .within(let slots):
            guard slots.count <= ProtocolLimits.maxSlotsPerValue else { throw ValidationError("Constraint.within", "too many slots") }
        case .dailyWindow(let from, let to):
            guard (0...1440).contains(from), (0...1440).contains(to), from < to else {
                throw ValidationError("Constraint.dailyWindow", "must satisfy 0 <= from < to <= 1440")
            }
        case .prefers(let liked, let avoided):
            guard liked.count + avoided.count <= ProtocolLimits.maxKeywordsPerValue * 2 else {
                throw ValidationError("Constraint.prefers", "too many keywords")
            }
        case .countBetween(let min, let max):
            guard 0 <= min, min <= max, max <= ProtocolLimits.maxCount else {
                throw ValidationError("Constraint.countBetween", "invalid range")
            }
        case .atMost, .atLeast, .mustBe:
            break
        }
        self.rule = rule
        self.strength = strength
    }
}

extension Constraint: Codable {
    private enum CodingKeys: String, CodingKey { case rule, strength }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(c.decode(Rule.self, forKey: .rule), strength: c.decode(Strength.self, forKey: .strength))
    }
}

/// All of the owner's constraints, grouped by issue.
public struct ConstraintSet: Hashable, Sendable {
    public static let maxConstraintsPerIssue = 8

    public let constraints: [IssueKey: [Constraint]]

    public init(_ constraints: [IssueKey: [Constraint]]) throws {
        guard constraints.count <= ProtocolLimits.maxIssuesPerTerms else {
            throw ValidationError("ConstraintSet", "more than \(ProtocolLimits.maxIssuesPerTerms) issues")
        }
        guard constraints.values.allSatisfy({ $0.count <= Self.maxConstraintsPerIssue }) else {
            throw ValidationError("ConstraintSet", "more than \(Self.maxConstraintsPerIssue) constraints on one issue")
        }
        self.constraints = constraints
    }

    public static let empty = try! ConstraintSet([:])

    public subscript(key: IssueKey) -> [Constraint] { constraints[key] ?? [] }
}

extension ConstraintSet: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode([IssueKey: [Constraint]].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(constraints)
    }
}

/// What the owner allows to leave the device for one issue. Enforced by the
/// `PolicyEngine`, never by the model (brief 3.5).
public struct DisclosureRule: Hashable, Sendable, Codable {
    public enum Action: String, Hashable, Sendable, Codable {
        /// Never send any value for this issue ("never share where I am").
        case never
        /// Show a consent sheet for every exchange that includes this issue.
        case askEachTime
        /// Send to paired peers whose agent runs on device, without asking.
        case allowOnDevicePeers
    }

    public let issue: IssueKey
    public let action: Action

    public init(issue: IssueKey, action: Action) {
        self.issue = issue
        self.action = action
    }
}

/// The structured result of interpreting the owner's plain-language rules or
/// intent. Shown to the owner for review before it is used.
public struct OwnerRules: Hashable, Sendable, Codable {
    public let constraints: ConstraintSet
    public let disclosure: [DisclosureRule]

    public init(constraints: ConstraintSet, disclosure: [DisclosureRule] = []) {
        self.constraints = constraints
        self.disclosure = disclosure
    }

    public static let empty = OwnerRules(constraints: .empty)
}
