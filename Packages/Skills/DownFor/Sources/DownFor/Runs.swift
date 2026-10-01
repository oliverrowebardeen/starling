import Foundation
import StarlingCore
import StarlingNegotiation

/// One pairwise exchange inside a group: the starter's conversation and the
/// friend on the other end.
struct RunKey: Hashable, Sendable {
    let conversation: ConversationID
    let peer: PeerID
}

/// What is needed to tell a friend "no plan" after the run is gone.
struct Notice: Sendable {
    let key: RunKey
    let mode: SendMode
    /// The request the notice is sent for; it goes only while that is live.
    let request: InteractionID
    let chainedFrom: ConversationID?
    let lastInbound: MessageID?
}

/// One friend's part of a group, from either side.
struct Run: Sendable {
    enum Role: Hashable, Sendable {
        /// We started the group; the peer is a candidate member.
        case hub
        /// The peer started the group; we answer it.
        case member
    }

    enum Phase: Hashable, Sendable {
        case psi
        /// Hub: waiting for answers. Member: waiting for queries or a proposal.
        case details
        /// Hub: answers are in; waiting for the group decision.
        case ready
        /// A proposal is out (hub) or on the owner's card (member).
        case proposed
        /// The member accepted the current proposal.
        case accepted
    }

    let key: RunKey
    let request: InteractionID
    let role: Role
    var phase = Phase.psi
    /// The starter's `chainedFrom`, carried on every envelope of the run.
    let chainedFrom: ConversationID?
    /// The starter's send mode, carried on every envelope of the run: a
    /// member echoes the mode it received (ADR 0020).
    let mode: SendMode
    let psiSessionID: UUID
    /// Nil for an invitation, which skips mutual reveal.
    let psi: (any PSISession)?
    let tokens: SlotTokenSet?
    /// Told to the policy with every PSI step: the provider and the free
    /// slots the set was built from (Core v1.1), and the interaction.
    let psiContext: OutboundContext
    var nextInboundPSIStep: UInt8
    var overlap: [TimeSlot]?

    // Hub: its queries and the answers.
    var queries: [MessageID: IssueKey] = [:]
    var pendingQueries: Set<IssueKey> = []
    var activityAnswer: [Keyword]?
    var askedActivities: [Keyword] = []

    // Member: issues answered, each once, and the queries by envelope, so
    // each answer tells the policy which query it answers.
    var answeredIssues: Set<IssueKey> = []
    var receivedQueries: [MessageID: Query] = [:]

    /// Hub: every envelope that carried the current proposal to the member.
    /// Member: every envelope the current proposal arrived in.
    var proposalEnvelopes: [MessageID] = []
    var terms: Terms?
    /// Member: the highest proposal round received. A lower round, even in
    /// a fresh envelope, is an old proposal and never replaces the card.
    var highestRound: UInt16?
    /// Hub: the proposal envelope the member's acceptance named, which the
    /// confirmation names back.
    var acceptedProposal: MessageID?
    /// Hub: the member accepted `terms`. Member: we did.
    var accepted = false
    var lastInbound: MessageID?

    // Retries and deadlines.
    var outstanding: [MessageBody] = []
    var attempts = 0
    var attemptLimit = 0
    var interval: Duration = .zero
    /// Steps that wait on people back off; steps between agents do not.
    var backsOff = false
    var timerToken = 0

    /// Replies already sent, so a duplicate gets the same reply without new
    /// work (and without a second model call).
    var replies: [Signature: Reply] = [:]

    /// A quiet ask: mutual reveal first.
    init(key: RunKey, request: InteractionID, role: Role, chainedFrom: ConversationID?, psiSessionID: UUID, psi: any PSISession, tokens: SlotTokenSet, provider: PSIProviderDescriptor) {
        self.key = key
        self.request = request
        self.role = role
        self.chainedFrom = chainedFrom
        mode = .askQuietly
        self.psiSessionID = psiSessionID
        self.psi = psi
        self.tokens = tokens
        psiContext = OutboundContext(psi: OutboundContext.PSIInputs(provider: provider, inputs: [.time: .slots(tokens.slots)]), interaction: request)
        nextInboundPSIStep = role == .hub ? 1 : 0
    }

    /// An invitation: the starter's proposal goes straight to the friend.
    init(invitation key: RunKey, request: InteractionID, role: Role, chainedFrom: ConversationID?, terms: Terms) {
        self.key = key
        self.request = request
        self.role = role
        self.chainedFrom = chainedFrom
        mode = .invite
        psiSessionID = UUID()
        psi = nil
        tokens = nil
        psiContext = OutboundContext(interaction: request)
        nextInboundPSIStep = 0
        phase = .proposed
        self.terms = terms
    }

    var notice: Notice { Notice(key: key, mode: mode, request: request, chainedFrom: chainedFrom, lastInbound: lastInbound) }

    /// A run we started whose first PSI step the friend has not answered:
    /// it has learned nothing from the friend.
    var isUnansweredStart: Bool { role == .hub && phase == .psi && nextInboundPSIStep == 1 }
}

/// What stays of a run that ended in a plan, so a late retry of the peer's
/// last message (a lost confirmation) still gets its reply.
struct Finished: Sendable {
    /// The request whose plan this was. Replies are replayed only while it
    /// is planned, and dropped when it ends.
    let request: InteractionID
    let replies: [Signature: Reply]
    let chainedFrom: ConversationID?
    let mode: SendMode
}

/// How a run ended. Never shown to anyone; only the request's lifecycle is.
enum RunOutcome: String, Hashable, Sendable {
    case matched
    /// PSI found no shared time.
    case noOverlap
    /// The peer said no plan, or the starter left us out.
    case rejected
    /// Left out of the group by the starter's plan.
    case excluded
    case timedOut
    case withdrawn
    /// A lower starter's run carries this pair instead.
    case yielded
    /// Policy or the owner's consent stopped a send.
    case policy
    /// A PSI error, a malformed step, or a value the gate refused.
    case failed
    /// The peer's card says it cannot run Down for... with us.
    case unsupported

    /// The request is done with this friend.
    var settles: Bool {
        switch self {
        case .noOverlap, .rejected, .excluded, .policy, .failed, .unsupported: true
        case .matched, .timedOut, .withdrawn, .yielded: false
        }
    }
}

/// Identifies an inbound message by content, since a retry arrives in a new
/// envelope with a new ID.
enum Signature: Hashable, Sendable {
    case psi(step: UInt8, payload: Data)
    case query(Query)
    case offer(Terms)
    case accept(Terms)

    init?(_ body: MessageBody) {
        switch body {
        case .psi(let frame): self = .psi(step: frame.step, payload: frame.payload)
        case .query(let query): self = .query(query)
        case .propose(let proposal): self = .offer(proposal.terms)
        case .accept(let acceptance): self = .accept(acceptance.terms)
        case .hello, .answer, .reject, .counter: return nil
        }
    }
}

/// A reply we sent, rebuilt against whichever copy of the inbound message
/// arrives next.
enum Reply: Hashable, Sendable {
    case psi(PSIFrame)
    /// A nil value means declined.
    case answer(issue: IssueKey, value: IssueValue?)
    /// A member's "I'm in" to a proposal.
    case accept(Terms)
    /// The starter's confirmation, answering a member's accept.
    case confirm(Terms)

    func body(answering inbound: Envelope) throws -> MessageBody {
        switch self {
        case .psi(let frame):
            return .psi(frame)
        case .answer(let issue, let value):
            return .answer(try Answer(query: inbound.id, issue: issue, status: value == nil ? .declined : .answered, acceptable: value))
        case .accept(let terms):
            return .accept(Acceptance(proposal: inbound.id, terms: terms))
        case .confirm(let terms):
            guard case .accept(let acceptance) = inbound.body else { throw ValidationError("Reply", "confirm answers an accept") }
            return .accept(Acceptance(proposal: acceptance.proposal, terms: terms))
        }
    }
}

/// Work for one friend's queue. Steps for one friend never interleave.
enum Work: Sendable {
    /// Start (or restart) the request's run with this friend, as starter.
    case start(InteractionID)
    case message(Envelope)
    case resend(RunKey, token: Int)
    case act(RunKey, Action)
    /// Tell a friend "no plan" after its run ended.
    case notify(Notice, Rejection.Reason)
}

enum Action: Sendable {
    /// Hub: send the current proposal.
    case propose
    /// Member: send "I'm in" to the current proposal.
    case accept
    /// Hub: confirm the plan to a member that accepted it.
    case confirm
}
