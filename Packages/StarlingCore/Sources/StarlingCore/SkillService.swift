import Foundation

// The runtime half of a skill (Phase 1.5, ADR 0010, 0011) and the model
// half (ADR 0016). A skill package implements `SkillService` over the
// app's single Outbox and Inbox; the shared lifecycle coordinator owns the
// `Interaction` records and applies the events a service reports.

/// Who a request goes to, as the owner chose in New.
public enum Audience: Hashable, Sendable, Codable {
    case allFriends
    /// The owner's own "close friends" list, kept on this phone.
    case closeFriends
    case picked([PeerID])
}

/// What the owner wants, structured: the chips Starling shows under
/// "Starling understood", after the owner's edits.
public struct SkillIntent: Hashable, Sendable {
    public let skill: SkillRef
    /// The intent's own constraints and sharing, merged with the standing
    /// rules by the app before the service sees them (ADR 0141).
    public let rules: OwnerRules
    public let audience: Audience
    public let expiresAt: Timestamp

    public init(skill: SkillRef, rules: OwnerRules, audience: Audience, expiresAt: Timestamp) {
        self.skill = skill
        self.rules = rules
        self.audience = audience
        self.expiresAt = expiresAt
    }
}

/// Everything a service needs to start one interaction as initiator.
public struct SkillRequest: Hashable, Sendable {
    public let interaction: InteractionID
    public let conversation: ConversationID
    public let intent: SkillIntent
    /// The audience resolved to paired peers that support the skill.
    public let participants: [PeerID]
    /// Artifacts from the interaction this one is chained to (ADR 0012).
    public let inputs: [Artifact]
    /// Sent as `Envelope.chainedFrom` on every message of the interaction.
    public let chainedFrom: ConversationID?

    public init(interaction: InteractionID, conversation: ConversationID, intent: SkillIntent, participants: [PeerID], inputs: [Artifact] = [], chainedFrom: ConversationID? = nil) {
        self.interaction = interaction
        self.conversation = conversation
        self.intent = intent
        self.participants = participants
        self.inputs = inputs
        self.chainedFrom = chainedFrom
    }
}

/// A question a skill's agent puts to its own owner (the "Just ask me
/// instead" fallback, or an invitee's review), with typed candidate answers.
/// The availability source's time-only `OwnerQuestion` stays for Phase 2's
/// `AvailabilitySource`.
public struct SkillQuestion: Hashable, Sendable {
    public let issue: IssueKey
    public let candidates: IssueValue
    public let asker: PeerID?

    public init(issue: IssueKey, candidates: IssueValue, asker: PeerID?) {
        self.issue = issue
        self.candidates = candidates
        self.asker = asker
    }
}

/// The owner's answer through the shared screens.
public enum OwnerAnswer: Hashable, Sendable {
    /// "I'm in", or yes to a question.
    case accept
    /// "Not tonight", or no.
    case pass
    /// A typed answer to a `SkillQuestion`, such as the slots that work.
    case reply(IssueValue)
}

/// A proposal card's facts. Wording comes from `SkillModel.proposalText`,
/// with a template fallback in the skill's package.
public struct SkillProposal: Hashable, Sendable {
    public let participants: [PeerID]
    public let terms: Terms
    public let plan: Plan?

    public init(participants: [PeerID], terms: Terms, plan: Plan? = nil) {
        self.participants = participants
        self.terms = terms
        self.plan = plan
    }
}

/// What a skill service reports to the lifecycle coordinator.
public enum SkillEvent: Hashable, Sendable {
    /// A friend's agent started an interaction with us. The coordinator
    /// creates an invitee `Interaction`; nothing starts a skill, asks for a
    /// permission, or notifies the owner because of this alone (ADR 0012).
    case incoming(InteractionID, conversation: ConversationID, from: PeerID, chainedFrom: ConversationID?)
    case lifecycle(InteractionID, InteractionEvent)
    case question(InteractionID, SkillQuestion)
    case proposal(InteractionID, SkillProposal)
    case produced(InteractionID, Artifact)
}

/// One skill's runtime. Every send goes through the app's `Outbox` with the
/// skill's `SkillRef`; every receive comes from the app's single Inbox loop
/// through `handle(_:)`.
public protocol SkillService: Sendable {
    var descriptor: SkillDescriptor { get }
    /// Single consumer: the lifecycle coordinator.
    var events: AsyncStream<SkillEvent> { get }
    func start(_ request: SkillRequest) async throws
    func answer(_ interaction: InteractionID, with answer: OwnerAnswer) async throws
    /// Friends learn nothing beyond "no plan".
    func withdraw(_ interaction: InteractionID) async
    /// Every InboxEvent; the service ignores envelopes for other skills.
    func handle(_ event: InboxEvent) async
    func shutdown() async
}

// MARK: - The model in the core loop (ADR 0016)

/// What New hands the model after routing: the chips, before the owner's edits.
public struct ParsedIntent: Hashable, Sendable {
    public let constraints: ConstraintSet
    public let audience: Audience?
    public let expiresAt: Timestamp?
    /// Names the owner typed ("with Priya"), resolved to friends on the phone.
    public let mentionedNames: [String]

    public init(constraints: ConstraintSet, audience: Audience? = nil, expiresAt: Timestamp? = nil, mentionedNames: [String] = []) {
        self.constraints = constraints
        self.audience = audience
        self.expiresAt = expiresAt
        self.mentionedNames = mentionedNames
    }
}

/// Facts for one proposal sentence. Names are the owner's own nicknames for
/// friends, never text a peer sent; values are typed (ARCHITECTURE rule 7).
public struct ProposalFacts: Hashable, Sendable {
    public let skill: SkillRef
    public let friendNames: [String]
    public let activity: Keyword?
    public let time: TimeSlot?
    public let place: PlaceName?
    public let timeZone: TimeZone

    public init(skill: SkillRef, friendNames: [String], activity: Keyword?, time: TimeSlot?, place: PlaceName?, timeZone: TimeZone) {
        self.skill = skill
        self.friendNames = friendNames
        self.activity = activity
        self.time = time
        self.place = place
        self.timeZone = timeZone
    }
}

/// The model's jobs in the core loop, beside `AgentModel`'s interpret,
/// match, and decide. Results are proposals for code and the owner to
/// check; nothing here decides egress or starts a skill.
public protocol SkillModel: Sendable {
    var descriptor: ModelDescriptor { get }
    /// Which skill fits the owner's words, or nil if none does.
    func route(_ utterance: String, among skills: [SkillDescriptor]) async throws -> ModelResult<SkillID?>
    /// The chips for one skill, from the owner's words.
    func intent(from utterance: String, for skill: SkillDescriptor, now: Date, timeZone: TimeZone) async throws -> ModelResult<ParsedIntent>
    /// One sentence for a proposal card, shown only on this phone.
    func proposalText(_ facts: ProposalFacts) async throws -> ModelResult<String>
}
