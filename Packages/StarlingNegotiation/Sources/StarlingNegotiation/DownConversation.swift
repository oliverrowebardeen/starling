import Foundation
import StarlingCore

/// One Down exchange with one friend: a PSI run, then (only if the run found
/// shared time) queries, offers, and the two acceptances.
struct DownConversation: Sendable {
    enum Phase: Hashable, Sendable {
        /// Running PSI.
        case psi
        /// Initiator: waiting for answers to its activity and budget queries.
        case awaitingAnswers
        /// Waiting for the peer to query or offer.
        case awaitingOffer
        /// Waiting for the peer to accept, counter, or reject our offer.
        case awaitingReply
        /// We accepted the peer's offer; waiting for its confirming accept.
        case awaitingConfirm
    }

    struct Offer: Hashable, Sendable {
        let round: UInt16
        let terms: Terms
        /// Every envelope that carried this offer (retries get new IDs).
        var envelopes: Set<MessageID>
    }

    let id: ConversationID
    let peer: PeerID
    let role: PSIRole
    let generation: Int
    let profile: DownProfile
    let psiSessionID: UUID
    let psi: any PSISession

    var phase = Phase.psi
    var nextInboundPSIStep: UInt8
    /// Shared slots, when the PSI run told us.
    var overlap: [TimeSlot]?

    // Initiator's queries.
    var queries: [MessageID: IssueKey] = [:]
    var pendingQueries: Set<IssueKey> = []
    var askedActivity = false
    var activityAnswer: [Keyword]?
    var budgetAnswer: MoneyAmount?

    var myOffer: Offer?
    var theirOffer: Offer?
    var history: [NegotiationRound] = []

    /// Resent on each timer tick until the peer replies.
    var outstanding: [MessageBody] = []
    var attempts = 0
    var timerToken = 0

    /// Replies already sent, so a duplicate gets the same reply without new
    /// work (and without a second model call).
    var replies: [DownSignature: DownReply] = [:]

    init(id: ConversationID, peer: PeerID, role: PSIRole, generation: Int, profile: DownProfile, psiSessionID: UUID, psi: any PSISession) {
        self.id = id
        self.peer = peer
        self.role = role
        self.generation = generation
        self.profile = profile
        self.psiSessionID = psiSessionID
        self.psi = psi
        nextInboundPSIStep = role == .initiator ? 1 : 0
    }
}

/// Identifies an inbound message by content, since a retry arrives in a new
/// envelope with a new ID.
enum DownSignature: Hashable, Sendable {
    case psi(step: UInt8, payload: Data)
    case query(Query)
    case offer(round: UInt16, terms: Terms)
    case accept(Terms)

    init?(_ body: MessageBody) {
        switch body {
        case .psi(let frame): self = .psi(step: frame.step, payload: frame.payload)
        case .query(let query): self = .query(query)
        case .propose(let proposal), .counter(let proposal): self = .offer(round: proposal.round, terms: proposal.terms)
        case .accept(let acceptance): self = .accept(acceptance.terms)
        case .hello, .answer, .reject: return nil
        }
    }
}

/// A reply we sent, rebuilt against whichever copy of the inbound message
/// arrives next.
enum DownReply: Hashable, Sendable {
    case psi(PSIFrame)
    /// A nil value means declined.
    case answer(issue: IssueKey, value: IssueValue?)
    case accept(Terms)
    case counter(round: UInt16, terms: Terms)
    case reject(Rejection.Reason)
    /// The offerer's confirming accept, answering the peer's accept.
    case confirm(Terms)

    func body(answering inbound: Envelope) throws -> MessageBody {
        switch self {
        case .psi(let frame):
            return .psi(frame)
        case .answer(let issue, let value):
            return .answer(try Answer(query: inbound.id, issue: issue, status: value == nil ? .declined : .answered, acceptable: value))
        case .accept(let terms):
            return .accept(Acceptance(proposal: inbound.id, terms: terms))
        case .counter(let round, let terms):
            return .counter(try Proposal(round: round, terms: terms, inReplyTo: inbound.id))
        case .reject(let reason):
            return .reject(Rejection(proposal: inbound.id, reason: reason))
        case .confirm(let terms):
            guard case .accept(let acceptance) = inbound.body else { throw ValidationError("DownReply", "confirm answers an accept") }
            return .accept(Acceptance(proposal: acceptance.proposal, terms: terms))
        }
    }
}

/// How a conversation ended. Only `matched` is ever visible to the owner.
enum DownOutcome: String, Hashable, Sendable {
    case matched
    /// PSI found no shared time, or the details did not fit.
    case noOverlap
    case rejected
    case timedOut
    /// The owner cleared or replaced the intent, or it expired.
    case withdrawn
    /// Lost a simultaneous start to the peer's run.
    case yielded
    /// Policy or the owner's consent stopped a send.
    case policy
    /// A PSI error, a malformed step, or a plan the gate refused.
    case failed
}
