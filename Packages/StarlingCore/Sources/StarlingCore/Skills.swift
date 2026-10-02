import Foundation

// Skills (Phase 1.5, ADR 0010). A skill is a user-facing feature (Down for…,
// Find a time, Pick a place, Swap photos) built on one negotiation building
// block. This file is the data half of a skill: what it is, what it touches,
// what it needs, and what it consumes and produces. The runtime half is
// `SkillService` (SkillService.swift); the model half is `SkillModel`.
// Nothing here imports FoundationModels or SwiftUI, so StarlingCore stays
// Foundation-only and every skill is testable with fakes.

// MARK: - Identity

/// Names a skill on the wire. Same format as `IssueKey`: a lowercase ASCII
/// letter, then up to 31 of `a-z 0-9 _`.
public struct SkillID: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        do {
            _ = try IssueKey(rawValue)
        } catch {
            throw ValidationError("SkillID", "must look like an IssueKey: a-z first, then a-z 0-9 _, at most 32")
        }
        self.rawValue = rawValue
    }

    init(known: String) { rawValue = known }

    public static let downFor = SkillID(known: "down_for")
    public static let findATime = SkillID(known: "find_a_time")
    public static let pickAPlace = SkillID(known: "pick_a_place")
    public static let swapPhotos = SkillID(known: "swap_photos")
    /// Change a confirmed plan: its time, place, activity, or who is in it
    /// (ADR 0022).
    public static let changePlan = SkillID(known: "change_plan")

    public var description: String { rawValue }
    public static func < (lhs: SkillID, rhs: SkillID) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension SkillID: Codable {
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A skill's protocol version, `major.minor`. Two agents can run a skill
/// together when the majors match; a minor bump only adds optional fields.
/// A2A's AgentSkill has no version field, so this is Starling's own (ADR 0010).
public struct SkillVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: UInt16
    public let minor: UInt16

    public init(_ major: UInt16, _ minor: UInt16 = 0) {
        self.major = major
        self.minor = minor
    }

    /// Parses `"1.2"`.
    public init(_ text: String) throws {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 5 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = UInt16(parts[0]), let minor = UInt16(parts[1])
        else { throw ValidationError("SkillVersion", "must be major.minor") }
        self.init(major, minor)
    }

    public func isCompatible(with other: SkillVersion) -> Bool { major == other.major }

    public var description: String { "\(major).\(minor)" }
    public static func < (lhs: SkillVersion, rhs: SkillVersion) -> Bool { (lhs.major, lhs.minor) < (rhs.major, rhs.minor) }
}

extension SkillVersion: Codable {
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A skill at a version, as advertised on an `AgentCard` and carried in an
/// `Envelope`.
public struct SkillRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public let id: SkillID
    public let version: SkillVersion

    public init(_ id: SkillID, _ version: SkillVersion) {
        self.id = id
        self.version = version
    }

    public var description: String { "\(id)@\(version)" }
}

// MARK: - What a skill is made of

/// The five StarlingKit building blocks (brief section 2.7). Each skill uses
/// exactly one.
public enum BuildingBlock: String, Hashable, Sendable, Codable, CaseIterable {
    case privateAggregation, mutualReveal, privateQuery, negotiationWithPrivateLimits, matchedExchange
}

/// How a request reaches friends (ADR 0020). Chosen in Compose, carried on
/// every envelope of the conversation.
public enum SendMode: String, Hashable, Sendable, Codable, CaseIterable {
    /// Mutual reveal: a friend sees nothing unless they are up for it too.
    /// "If nobody's up for it, nobody sees you asked."
    case askQuietly = "ask_quietly"
    /// The friend's agent shows the request as a card.
    case invite
}

/// System permissions a skill may need. Requested just in time, the first
/// time the owner uses the feature that needs it, never at launch (ADR 0013).
public enum SystemPermission: String, Hashable, Sendable, Codable, CaseIterable {
    /// EventKit full access. Reading events needs full access; there is no
    /// read-only level.
    case calendarFullAccess
    case locationWhenInUse
    case photoLibrary
}

/// The typed results skills hand to each other (ADR 0012).
public enum ArtifactKind: String, Hashable, Sendable, Codable, CaseIterable {
    case plan, timeSlot, placeChoice, attendees
}

/// When a chained skill may start, once the owner has opted in (ADR 0012).
public enum ChainTrigger: String, Hashable, Sendable, Codable {
    /// Offered at Confirm, under "Keep it going".
    case atConfirm
    /// Starts by itself when the plan it follows ends (Swap photos), only if
    /// the owner opted in at Confirm.
    case afterPlanEnds
    /// Started by the owner from the plan's detail, any time after it is
    /// confirmed and before it ends (Change the plan, ADR 0022).
    case whilePlanned = "while_planned"
}

/// One field the model fills from the owner's words for a skill, named by
/// the issue it constrains (ADR 0016).
public struct IntentSlot: Hashable, Sendable {
    public let issue: IssueKey
    public let required: Bool
    /// What to look for, in plain words, for the model's prompt. Written by
    /// the skill's authors, never by a peer.
    public let hint: String

    public init(_ issue: IssueKey, required: Bool, hint: String) throws {
        guard !hint.isEmpty, hint.count <= 120 else { throw ValidationError("IntentSlot.hint", "must be 1-120 characters") }
        self.issue = issue
        self.required = required
        self.hint = hint
    }
}

/// What a skill reads from free text. The model extracts it into
/// `ConstraintSet` rules, which the owner sees as editable chips; StarlingAgent
/// builds the guided-generation schema from this at runtime (ADR 0016).
public struct IntentSchema: Hashable, Sendable {
    public let slots: [IntentSlot]
    /// Whether the skill asks who to involve (All friends, Close friends, Pick).
    public let asksForAudience: Bool
    /// Whether the request can expire ("Expires in 3 hrs").
    public let asksForExpiry: Bool

    public init(slots: [IntentSlot], asksForAudience: Bool = true, asksForExpiry: Bool = true) throws {
        guard (1...ProtocolLimits.maxIssuesPerTerms).contains(slots.count) else {
            throw ValidationError("IntentSchema.slots", "must have 1-\(ProtocolLimits.maxIssuesPerTerms) slots")
        }
        guard Set(slots.map(\.issue)).count == slots.count else { throw ValidationError("IntentSchema.slots", "duplicate issue") }
        self.slots = slots
        self.asksForAudience = asksForAudience
        self.asksForExpiry = asksForExpiry
    }

    public var requiredIssues: Set<IssueKey> { Set(slots.filter(\.required).map(\.issue)) }
}

/// The fixed words a skill shows, so shared lifecycle screens can render any
/// skill (ADR 0011, 0017). Proposal sentences come from `SkillModel` with a
/// template fallback in the skill's package.
public struct SkillWording: Hashable, Sendable {
    /// "Down for…"
    public let name: String
    /// Tile subtitle in New: "See who's up for something".
    public let summary: String
    /// Primary button in New: "See who's up for it".
    public let startAction: String
    /// "I'm in"
    public let acceptAction: String
    /// "Not tonight"
    public let declineAction: String
    /// "If you pass, they just won't see it."
    public let declineNote: String

    public init(name: String, summary: String, startAction: String, acceptAction: String, declineAction: String, declineNote: String) {
        self.name = name
        self.summary = summary
        self.startAction = startAction
        self.acceptAction = acceptAction
        self.declineAction = declineAction
        self.declineNote = declineNote
    }
}

/// Privacy topics and system permissions together: what running a skill
/// exposes. A chained skill that adds either needs a fresh Consent (ADR 0012).
public struct SkillExposure: Hashable, Sendable {
    public let topics: Set<PrivacyTopic>
    public let permissions: Set<SystemPermission>

    public init(topics: Set<PrivacyTopic> = [], permissions: Set<SystemPermission> = []) {
        self.topics = topics
        self.permissions = permissions
    }

    public static let none = SkillExposure()

    public var isEmpty: Bool { topics.isEmpty && permissions.isEmpty }

    /// What `self` exposes that `granted` does not.
    public func adding(over granted: SkillExposure) -> SkillExposure {
        SkillExposure(topics: topics.subtracting(granted.topics), permissions: permissions.subtracting(granted.permissions))
    }

    public func union(_ other: SkillExposure) -> SkillExposure {
        SkillExposure(topics: topics.union(other.topics), permissions: permissions.union(other.permissions))
    }
}

/// Everything StarlingKit needs to know about a skill without running it.
/// Each skill package defines one; the registry holds them (ADR 0010).
public struct SkillDescriptor: Hashable, Sendable, Identifiable {
    public let ref: SkillRef
    public let wording: SkillWording
    public let buildingBlock: BuildingBlock
    /// Every topic the skill may send a value for or use on the phone.
    public let topicsUsed: Set<PrivacyTopic>
    /// Topics whose own values must leave the phone for the skill to run at
    /// all, such as photos for Swap photos. A topic the skill only uses
    /// locally is not required: Never keeps its value on the phone but does
    /// not stop the skill (ADR 0019). A subset of `topicsUsed`.
    public let topicsRequired: Set<PrivacyTopic>
    public let permissions: Set<SystemPermission>
    public let accepts: Set<ArtifactKind>
    public let produces: Set<ArtifactKind>
    public let intent: IntentSchema
    public let chainTrigger: ChainTrigger
    /// The modes Compose offers, the first being the default. Ask quietly
    /// needs the mutual reveal building block (ADR 0020).
    public let sendModes: [SendMode]

    public init(
        ref: SkillRef,
        wording: SkillWording,
        buildingBlock: BuildingBlock,
        topicsUsed: Set<PrivacyTopic>,
        topicsRequired: Set<PrivacyTopic>,
        permissions: Set<SystemPermission> = [],
        accepts: Set<ArtifactKind> = [],
        produces: Set<ArtifactKind>,
        intent: IntentSchema,
        chainTrigger: ChainTrigger = .atConfirm,
        sendModes: [SendMode] = [.invite]
    ) throws {
        guard topicsRequired.isSubset(of: topicsUsed) else {
            throw ValidationError("SkillDescriptor.topicsRequired", "must be a subset of topicsUsed")
        }
        for slot in intent.slots {
            guard let topic = PrivacyTopic(issue: slot.issue), topicsUsed.contains(topic) else {
                throw ValidationError("SkillDescriptor.intent", "slot \(slot.issue) is not covered by topicsUsed")
            }
        }
        guard !sendModes.isEmpty, Set(sendModes).count == sendModes.count else {
            throw ValidationError("SkillDescriptor.sendModes", "must list at least one mode, each once")
        }
        guard !sendModes.contains(.askQuietly) || buildingBlock == .mutualReveal else {
            throw ValidationError("SkillDescriptor.sendModes", "ask quietly needs the mutual reveal building block")
        }
        self.ref = ref
        self.wording = wording
        self.buildingBlock = buildingBlock
        self.topicsUsed = topicsUsed
        self.topicsRequired = topicsRequired
        self.permissions = permissions
        self.accepts = accepts
        self.produces = produces
        self.intent = intent
        self.chainTrigger = chainTrigger
        self.sendModes = sendModes
    }

    /// The mode Compose starts with.
    public var defaultSendMode: SendMode { sendModes[0] }

    public var id: SkillID { ref.id }

    public var exposure: SkillExposure { SkillExposure(topics: topicsUsed, permissions: permissions) }

    /// Required topics the owner set to Never. Non-empty means the skill must
    /// explain why it cannot run instead of failing silently (ADR 0014,
    /// narrowed by ADR 0019 to values that must leave).
    public func blockingTopics(in settings: PrivacySettings) -> Set<PrivacyTopic> {
        topicsRequired.intersection(settings.neverTopics)
    }

    /// Whether this skill can follow `previous` in a chain: it accepts at
    /// least one artifact kind `previous` produces.
    public func canFollow(_ previous: SkillDescriptor) -> Bool {
        !accepts.isDisjoint(with: previous.produces)
    }
}
