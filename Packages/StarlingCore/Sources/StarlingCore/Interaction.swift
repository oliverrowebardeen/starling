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

/// The live steps a consent sheet can interrupt. Any send can need consent:
/// a PSI step while negotiating, or the acceptance the owner's "I'm in"
/// sends from a proposal.
public enum ConsentResume: String, Hashable, Sendable, Codable, CaseIterable {
    case negotiating, awaitingOwner, proposed, confirmed

    public var state: InteractionState {
        switch self {
        case .negotiating: .negotiating
        case .awaitingOwner: .awaitingOwner
        case .proposed: .proposed
        case .confirmed: .confirmed
        }
    }
}

public enum InteractionState: Hashable, Sendable, Codable {
    /// Compose: the owner is still shaping the request.
    case drafting
    /// Consent: a consent sheet is waiting for the owner. Granting it
    /// resumes the interrupted step.
    case awaitingConsent(resume: ConsentResume)
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
    /// The owner sent the request. Only the lifecycle coordinator applies
    /// it, before calling `SkillService.start`; an invitee interaction is
    /// created negotiating and never receives it (ADR 0011, amendment 13).
    case started
    /// A send is waiting on the consent sheet. `request` tells overlapping
    /// requests in one interaction apart.
    case consentNeeded(request: UInt32)
    /// The owner approved that request.
    case consentGiven(request: UInt32)
    /// The agent needs its owner to answer this question. The content
    /// travels with the event, so the stored question is always the one
    /// the state machine is waiting on.
    case ownerNeeded(SkillQuestion)
    /// The owner answered the question with this revision.
    case ownerAnswered(question: UInt32)
    /// A proposal card is ready, with its content and revision together.
    /// Revisions only increase; a newer one replaces any proposal the owner
    /// has not answered.
    case proposalReady(SkillProposal)
    /// The owner said yes ("I'm in") to exactly this proposal revision.
    case ownerAccepted(revision: UInt32)
    /// The owner passed ("Not tonight") or declined consent.
    case ownerPassed
    /// Everyone accepted exactly this proposal revision.
    case everyoneConfirmed(revision: UInt32)
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

/// A consent completion for a request this interaction is not waiting on,
/// or a request ID at or below one already used (IDs only increase): a late
/// or replayed completion never resumes a later suspension.
public struct UnknownConsentRequest: Error, Hashable, Sendable {
    public let request: UInt32

    public init(request: UInt32) { self.request = request }
}

/// An acceptance or confirmation for a proposal that is no longer the
/// current one, or a proposal that does not move the revision forward.
/// The owner's tap on an older card never accepts newer terms.
public struct StaleProposal: Error, Hashable, Sendable {
    public let current: UInt32?
    public let event: InteractionEvent

    public init(current: UInt32?, event: InteractionEvent) {
        self.current = current
        self.event = event
    }
}

/// A question that does not move the question revision forward, or an
/// answer to a question that is not the pending one.
public struct StaleQuestion: Error, Hashable, Sendable {
    public let current: UInt32?
    public let event: InteractionEvent

    public init(current: UInt32?, event: InteractionEvent) {
        self.current = current
        self.event = event
    }
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

        case (.negotiating, .consentNeeded): return .awaitingConsent(resume: .negotiating)
        case (.awaitingOwner, .consentNeeded): return .awaitingConsent(resume: .awaitingOwner)
        case (.proposed, .consentNeeded): return .awaitingConsent(resume: .proposed)
        case (.confirmed, .consentNeeded): return .awaitingConsent(resume: .confirmed)
        // Another send asks while a sheet is already up: still suspended.
        case (.awaitingConsent(let resume), .consentNeeded): return .awaitingConsent(resume: resume)
        case (.awaitingConsent(let resume), .consentGiven): return resume.state
        case (.awaitingConsent, .ownerPassed): return .ended(.declined)
        // The others gave up while the sheet was open.
        case (.awaitingConsent, .noAgreement): return .ended(.nobodyUp)

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
    /// The current proposal, content and revision together, set only by
    /// `proposalReady`, so the card always shows the terms the owner accepts
    /// and survives an app restart.
    public private(set) var proposal: SkillProposal?
    /// The question the agent is waiting for its owner to answer, set only
    /// by `ownerNeeded`.
    public private(set) var pendingQuestion: SkillQuestion?
    /// Consent requests still waiting on the owner. The interaction resumes
    /// only when the last one is approved.
    public private(set) var pendingConsents: Set<UInt32>
    /// The highest question revision and consent request ID used so far.
    /// Both start at 1 and only increase, so a completed one can never be
    /// reopened or replayed, including after a restart.
    public private(set) var questionWatermark: UInt32
    public private(set) var consentWatermark: UInt32

    /// The revision of the proposal the owner is looking at or accepted.
    public var proposalRevision: UInt32? { proposal?.revision }

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
        proposal = nil
        pendingQuestion = nil
        pendingConsents = []
        questionWatermark = 0
        consentWatermark = 0
    }

    public var updatedAt: Timestamp { history.last?.at ?? createdAt }

    /// Applies `event`, recording the new state. Throws `InvalidTransition`,
    /// `StaleProposal`, `StaleQuestion`, or `UnknownConsentRequest` and
    /// leaves the interaction unchanged if the event does not apply.
    public mutating func apply(_ event: InteractionEvent, at time: Timestamp) throws {
        switch event {
        case .proposalReady(let proposal):
            if let current = proposalRevision, proposal.revision <= current { throw StaleProposal(current: current, event: event) }
        case .ownerAccepted(let revision), .everyoneConfirmed(let revision):
            guard revision == proposalRevision else { throw StaleProposal(current: proposalRevision, event: event) }
        case .ownerNeeded(let question):
            guard question.revision > questionWatermark else { throw StaleQuestion(current: questionWatermark, event: event) }
        case .ownerAnswered(let revision):
            guard revision == pendingQuestion?.revision else { throw StaleQuestion(current: pendingQuestion?.revision, event: event) }
        case .consentNeeded(let request):
            guard request > consentWatermark else { throw UnknownConsentRequest(request: request) }
        case .consentGiven(let request):
            guard pendingConsents.contains(request) else { throw UnknownConsentRequest(request: request) }
            // Other requests are still open: stay suspended, with no new
            // state in the history.
            if pendingConsents.count > 1, case .awaitingConsent = state {
                pendingConsents.remove(request)
                return
            }
        default:
            break
        }
        let next = try state.applying(event)
        // A second request while a sheet is already up changes nothing the
        // timeline shows; every other event, a replacement proposal
        // included, is recorded.
        let alreadySuspended: Bool = if case .consentNeeded = event, case .awaitingConsent = state { true } else { false }
        state = next
        if !alreadySuspended { history.append(StateChange(state: next, at: time)) }
        switch event {
        case .proposalReady(let proposal): self.proposal = proposal
        case .ownerNeeded(let question):
            pendingQuestion = question
            questionWatermark = question.revision
        case .ownerAnswered, .ownerPassed: pendingQuestion = nil
        case .consentNeeded(let request):
            pendingConsents.insert(request)
            consentWatermark = request
        case .consentGiven(let request): pendingConsents.remove(request)
        default: break
        }
        if next.isFinal {
            pendingConsents = []
            pendingQuestion = nil
        }
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
