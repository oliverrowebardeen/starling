import Foundation

// One lifecycle for every skill (Phase 1.5, ADR 0011): Compose, Consent,
// Negotiate, Propose, Confirm, Hand off, Remember. Skills never build their
// own screens for these steps; they emit `InteractionEvent`s, and the shared
// coordinator applies them to this state machine and persists the result in
// an `InteractionStore`. Home groups interactions by `homeSection`.

public struct InteractionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var description: String { rawValue.uuidString }
}

/// The seven steps, for screens that show where an interaction is.
public enum LifecycleStep: String, Hashable, Sendable, Codable, CaseIterable {
    case compose, consent, negotiate, propose, confirm, handOff, remember
}

/// Whether this phone started the interaction or was asked.
public enum InteractionRole: String, Hashable, Sendable, Codable {
    case initiator, invitee
}

/// Why an interaction ended without (or after) a plan. Several of these are
/// silent on purpose: one-sided interest notifies nobody (brief 2.6).
public enum EndReason: String, Hashable, Sendable, Codable {
    /// The owner passed or declined consent. Others "just won't see it".
    case declined
    /// Nobody else was up for it; nobody sees the owner asked.
    case nobodyUp
    case expired
    /// The owner withdrew the request.
    case withdrawn
    case failed
    /// No participant runs the skill at a compatible version.
    case unsupported
    /// A topic the skill requires is set to Never (ADR 0014).
    case blockedByPrivacy
}

/// Where Home lists an interaction.
public enum HomeSection: String, Hashable, Sendable, Codable {
    case needsYou, inProgress, comingUp, history
}

public enum InteractionState: Hashable, Sendable, Codable {
    /// Compose: the owner is still shaping the request.
    case drafting
    /// Consent: a consent sheet is waiting for the owner.
    case awaitingConsent
    /// Negotiate: agents are working; the status mark moves.
    case negotiating
    /// The agent needs one answer from its owner (ask-me fallback, or an
    /// invitee reviewing a request such as "when are you free next week?").
    case awaitingOwner
    /// Propose: a proposal card waits for the owner's answer.
    case proposed
    /// Confirm: the owner said yes; waiting for the others.
    case confirmed
    /// Everyone said yes: "It's a plan". Hand-offs happen from here.
    case planned
    /// Remember: the plan's time has passed.
    case done
    case ended(EndReason)

    public var step: LifecycleStep {
        switch self {
        case .drafting: .compose
        case .awaitingConsent: .consent
        case .negotiating, .awaitingOwner: .negotiate
        case .proposed: .propose
        case .confirmed: .confirm
        case .planned: .handOff
        case .done, .ended: .remember
        }
    }

    public var homeSection: HomeSection {
        switch self {
        case .awaitingConsent, .awaitingOwner, .proposed: .needsYou
        case .drafting, .negotiating, .confirmed: .inProgress
        case .planned: .comingUp
        case .done, .ended: .history
        }
    }

    public var isFinal: Bool {
        switch self {
        case .done, .ended: true
        default: false
        }
    }
}

/// What a skill (or the owner, through the shared screens) reports. The
/// state machine decides what each one means in each state.
public enum InteractionEvent: Hashable, Sendable, Codable {
    /// The owner sent the request (initiator), or the agent started handling
    /// an incoming one (invitee).
    case started
    case consentNeeded
    case consentGiven
    case ownerNeeded
    case ownerAnswered
    case proposalReady
    /// The owner said yes ("I'm in").
    case ownerAccepted
    /// The owner passed ("Not tonight") or declined consent.
    case ownerPassed
    case everyoneConfirmed
    /// Negotiation ended with no agreement.
    case noAgreement
    case expired
    case withdrawn
    case failed
    case unsupported
    case blockedByPrivacy
    /// The planned time has passed.
    case planEnded
}

public struct InvalidTransition: Error, Hashable, Sendable {
    public let from: InteractionState
    public let event: InteractionEvent
}

extension InteractionState {
    /// The state after `event`, or `InvalidTransition`. Final states accept
    /// nothing, so a late or replayed event can never revive an interaction.
    public func applying(_ event: InteractionEvent) throws -> InteractionState {
        switch (self, event) {
        case (.done, _), (.ended, _):
            throw InvalidTransition(from: self, event: event)

        // Ends that can happen at any live step.
        case (_, .withdrawn): return .ended(.withdrawn)
        case (_, .expired): return .ended(.expired)
        case (_, .failed): return .ended(.failed)

        case (.drafting, .started): return .negotiating
        case (.drafting, .unsupported): return .ended(.unsupported)
        case (.drafting, .blockedByPrivacy): return .ended(.blockedByPrivacy)

        case (.negotiating, .consentNeeded): return .awaitingConsent
        case (.awaitingConsent, .consentGiven): return .negotiating
        case (.awaitingConsent, .ownerPassed): return .ended(.declined)

        case (.negotiating, .ownerNeeded): return .awaitingOwner
        case (.awaitingOwner, .ownerAnswered): return .negotiating
        case (.awaitingOwner, .ownerPassed): return .ended(.declined)

        case (.negotiating, .proposalReady): return .proposed
        case (.negotiating, .noAgreement): return .ended(.nobodyUp)
        case (.negotiating, .unsupported): return .ended(.unsupported)
        case (.negotiating, .blockedByPrivacy): return .ended(.blockedByPrivacy)

        case (.proposed, .ownerAccepted): return .confirmed
        case (.proposed, .ownerPassed): return .ended(.declined)
        case (.proposed, .noAgreement): return .ended(.nobodyUp)
        // A newer proposal replaces one the owner has not answered.
        case (.proposed, .proposalReady): return .proposed

        case (.confirmed, .everyoneConfirmed): return .planned
        case (.confirmed, .noAgreement): return .ended(.nobodyUp)
        // Someone else passed and the agents are trying again.
        case (.confirmed, .proposalReady): return .proposed

        case (.planned, .planEnded): return .done

        default:
            throw InvalidTransition(from: self, event: event)
        }
    }
}

/// One state an interaction passed through, for "How this came together".
public struct StateChange: Hashable, Sendable, Codable {
    public let state: InteractionState
    public let at: Timestamp

    public init(state: InteractionState, at: Timestamp) {
        self.state = state
        self.at = at
    }
}

/// How a chained interaction follows an earlier one (ADR 0012). The owner
/// opted in at Confirm; a peer's message can never create one.
public struct ChainLink: Hashable, Sendable, Codable {
    public let parent: InteractionID
    /// The parent's conversation, sent as `Envelope.chainedFrom`.
    public let parentConversation: ConversationID
    public let consumed: [ArtifactKind]
    public let trigger: ChainTrigger
    public let optedInAt: Timestamp

    public init(parent: InteractionID, parentConversation: ConversationID, consumed: [ArtifactKind], trigger: ChainTrigger, optedInAt: Timestamp) {
        self.parent = parent
        self.parentConversation = parentConversation
        self.consumed = consumed
        self.trigger = trigger
        self.optedInAt = optedInAt
    }
}

/// What left the phone in one send, for "What left your phone". Recorded by
/// an `OutboxObserver` from the same items the consent sheet shows.
public struct EgressRecord: Hashable, Sendable, Codable {
    public let at: Timestamp
    public let recipient: PeerID
    public let items: [DisclosedItem]

    public init(at: Timestamp, recipient: PeerID, items: [DisclosedItem]) {
        self.at = at
        self.recipient = recipient
        self.items = items
    }

    /// The topics this send touched.
    public var topics: Set<PrivacyTopic> { Set(items.compactMap { $0.issue.flatMap(PrivacyTopic.init(issue:)) }) }
}

/// One use of one skill, from Compose to Remember, on this phone.
public struct Interaction: Hashable, Sendable, Codable, Identifiable {
    public let id: InteractionID
    /// Shared with the peers: every envelope of the interaction carries it.
    public let conversation: ConversationID
    public let skill: SkillRef
    public let role: InteractionRole
    public private(set) var participants: [PeerID]
    public private(set) var state: InteractionState
    public let createdAt: Timestamp
    public private(set) var history: [StateChange]
    public let chain: ChainLink?
    public private(set) var artifacts: [Artifact]
    public private(set) var egress: [EgressRecord]

    /// An initiator starts while drafting; an invitee starts negotiating,
    /// because its agent is already handling the request.
    public init(
        id: InteractionID = InteractionID(),
        conversation: ConversationID = ConversationID(),
        skill: SkillRef,
        role: InteractionRole,
        participants: [PeerID],
        createdAt: Timestamp,
        chain: ChainLink? = nil
    ) {
        let initial: InteractionState = role == .initiator ? .drafting : .negotiating
        self.id = id
        self.conversation = conversation
        self.skill = skill
        self.role = role
        self.participants = participants
        state = initial
        self.createdAt = createdAt
        history = [StateChange(state: initial, at: createdAt)]
        self.chain = chain
        artifacts = []
        egress = []
    }

    public var updatedAt: Timestamp { history.last?.at ?? createdAt }

    /// Applies `event`, recording the new state. Throws `InvalidTransition`
    /// and leaves the interaction unchanged if the event does not apply.
    public mutating func apply(_ event: InteractionEvent, at time: Timestamp) throws {
        let next = try state.applying(event)
        state = next
        history.append(StateChange(state: next, at: time))
    }

    public mutating func setParticipants(_ peers: [PeerID]) { participants = peers }

    /// Records an artifact this interaction produced. A newer artifact of the
    /// same kind replaces the older one (a plan updated with a place).
    public mutating func record(_ artifact: Artifact) {
        artifacts.removeAll { $0.kind == artifact.kind }
        artifacts.append(artifact)
    }

    public mutating func record(_ send: EgressRecord) { egress.append(send) }

    public var plan: Plan? {
        artifacts.lazy.compactMap { if case .plan(let plan) = $0 { plan } else { nil } }.first
    }
}

/// Persists interactions on the device. Lane-owned implementations decide
/// the storage; `StarlingFakes.InMemoryInteractionStore` is the test double.
public protocol InteractionStore: Sendable {
    func all() async throws -> [Interaction]
    func interaction(_ id: InteractionID) async throws -> Interaction?
    func interaction(conversation: ConversationID) async throws -> Interaction?
    /// Inserts or replaces the interaction with the same ID.
    func save(_ interaction: Interaction) async throws
    func remove(_ id: InteractionID) async throws
}

extension Collection where Element == Interaction {
    /// `root` and every interaction chained after it, in the order they
    /// started, for a plan's "How this came together" timeline.
    public func chain(from root: InteractionID) -> [Interaction] {
        var included: Set<InteractionID> = [root]
        var result = filter { $0.id == root }
        var grew = true
        while grew {
            grew = false
            for item in self where !included.contains(item.id) {
                if let parent = item.chain?.parent, included.contains(parent) {
                    included.insert(item.id)
                    result.append(item)
                    grew = true
                }
            }
        }
        return result.sorted { $0.createdAt < $1.createdAt }
    }
}
