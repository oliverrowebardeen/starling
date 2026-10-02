import Foundation

public enum OutboxError: Error, Hashable, Sendable {
    case denied(PolicyViolation)
    case consentDeclined
    /// The policy's answer changed after it cleared the send: while the
    /// owner was deciding (v1.1), or while the send waited its turn, for
    /// example after a stricter setting (ADR 0021); nothing was sent.
    case policyChangedDuringConsent
    /// The conversation has used every sequence number; nothing was sent,
    /// because the next number would repeat one the friend has seen.
    case sequenceExhausted
    /// The conversation has ended on this phone; nothing is sent in it again
    /// (ADR 0021).
    case conversationRetired
    /// The answer would tell this friend about more candidates of the issue
    /// than `ProtocolLimits.maxCandidatesAnsweredPerIssue` allows in this
    /// conversation; nothing was sent (ADR 0021).
    case answerLimitReached
    /// With a ledger installed, an answer must name the query it answers in
    /// `OutboundContext.answering`, with the same issue; nothing was sent.
    case answerWithoutItsQuery
}

/// Told about every envelope the transport accepted, for example to keep an
/// audit log. Never told about denied, declined, cancelled, or failed sends.
/// `Outbox` calls the method with `disclosed`, which by default forwards to
/// the three-argument one; implement it as well when you need the items.
public protocol OutboxObserver: Sendable {
    /// Called after the send is cleared and before anything leaves. Throwing
    /// stops the send, so an audit can durably note a send it will hear about
    /// in `didSend` (ADR 0021). Does nothing by default.
    func outbox(willSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async throws
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async
    /// - Parameter disclosed: What the send disclosed: the consent sheet's
    ///   items, or for a send allowed without a sheet the policy's own list.
    ///   Nil when the policy could not say.
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async
}

extension OutboxObserver {
    public func outbox(willSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async throws {}

    public func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async {
        await outbox(didSend: envelope, context: context, decision: decision)
    }
}

/// Remembers, across launches, the highest sequence number this phone sent
/// in each conversation, so a relaunch continues above it even if the clock
/// moved back (review of PR #57). Called synchronously from `Outbox` with no
/// suspension between numbering and sending, so implementations must be
/// fast and thread-safe. The app persists it; without one, a conversation
/// restarts at the clock in milliseconds.
public protocol SentSequenceStore: Sendable {
    func highestSent(in conversation: ConversationID, to recipient: PeerID) -> UInt64?
    /// Durably records `sequence` before the envelope leaves. Throwing stops
    /// the send, so a number is never sent without being recorded, and a
    /// later `highestSent` must reflect every recorded number.
    func recordSent(_ sequence: UInt64, in conversation: ConversationID, to recipient: PeerID) throws
}

/// The only sanctioned way to send a message.
///
/// Every envelope passes the `PolicyEngine`, and the owner's consent when the
/// policy asks for it, before it is encoded and handed to the transport.
/// Features never hold a transport for sending; they hold an `Outbox`.
public actor Outbox {
    private let transport: any Transport
    private let policy: any PolicyEngine
    private let consent: any ConsentProvider
    private let codec: EnvelopeCodec
    private let observer: (any OutboxObserver)?
    private let sequences: (any SentSequenceStore)?
    private let ledger: (any ConversationLedger)?
    private let now: @Sendable () -> Date
    /// Numbers run per conversation and recipient, so a friend never sees
    /// how many envelopes went to anyone else (review of PR #60).
    private struct SequenceKey: Hashable { let conversation: ConversationID; let recipient: PeerID }
    private var nextSequence: [SequenceKey: UInt64] = [:]
    /// Each key's sends are numbered and handed to the transport one at a
    /// time, so a send cancelled while it waits takes no number.
    private var tails: [SequenceKey: Task<Void, Never>] = [:]
    /// Sends not yet finished, by conversation, so `retire(_:)` can stop them.
    private var inFlight: [ConversationID: [UUID: Task<Envelope, any Error>]] = [:]

    public init(
        transport: any Transport,
        policy: any PolicyEngine,
        consent: any ConsentProvider,
        codec: EnvelopeCodec = EnvelopeCodec(),
        observer: (any OutboxObserver)? = nil,
        sequences: (any SentSequenceStore)? = nil,
        ledger: (any ConversationLedger)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.policy = policy
        self.consent = consent
        self.codec = codec
        self.observer = observer
        self.sequences = sequences
        self.ledger = ledger
        self.now = now
    }

    /// Milliseconds since 1970, or 0 for a clock set before 1970.
    static func firstSequence(at date: Date) -> UInt64 {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded(.down)
        return milliseconds > 0 ? UInt64(milliseconds) : 0
    }

    /// Builds, checks, and sends one envelope. Returns what was sent.
    @discardableResult
    public func send(
        _ body: MessageBody,
        to recipient: PeerID,
        conversation: ConversationID,
        recipientCard: AgentCard? = nil,
        context: OutboundContext = .empty,
        skill: SkillRef? = nil,
        mode: SendMode? = nil,
        chainedFrom: ConversationID? = nil
    ) async throws -> Envelope {
        // The whole send, from the policy and the consent sheet onward, runs
        // as one task registered from the start, so cancelInFlight() and
        // retire(_:) reach it wherever it waits: on a sheet, in willSend, in
        // the per-friend queue, or in the transport (issue #81). The
        // caller's own cancellation reaches it too.
        let pipeline = Task { () async throws -> Envelope in
            try await self.pipeline(body, to: recipient, conversation: conversation, recipientCard: recipientCard,
                                    context: context, skill: skill, mode: mode, chainedFrom: chainedFrom)
        }
        let id = UUID()
        inFlight[conversation, default: [:]][id] = pipeline
        defer {
            inFlight[conversation]?[id] = nil
            if inFlight[conversation]?.isEmpty == true { inFlight[conversation] = nil }
        }
        return try await withTaskCancellationHandler {
            try await pipeline.value
        } onCancel: {
            pipeline.cancel()
        }
    }

    private func pipeline(
        _ body: MessageBody,
        to recipient: PeerID,
        conversation: ConversationID,
        recipientCard: AgentCard?,
        context: OutboundContext,
        skill: SkillRef?,
        mode: SendMode?,
        chainedFrom: ConversationID?
    ) async throws -> Envelope {
        // The policy judges a draft. The number and send time are set only
        // once the send is cleared (below), so nothing about a refused send
        // shows on the wire.
        let draft = try Envelope(
            conversation: conversation,
            sender: transport.localPeer,
            recipient: recipient,
            sequence: 0,
            sentAt: Timestamp(now()),
            body: body,
            skill: skill,
            mode: mode,
            chainedFrom: chainedFrom
        )

        let message = OutboundMessage(envelope: draft, recipientCard: recipientCard, transport: transport.kind, context: context)
        let decision = await policy.evaluate(message)
        switch decision {
        case .allow:
            break
        case .deny(let violation):
            throw OutboxError.denied(violation)
        case .needsConsent(let disclosure):
            guard await consent.requestConsent(for: disclosure) == .approved else { throw OutboxError.consentDeclined }
            // The owner may take a long time. Honor cancellation, and send
            // only if the policy still gives the same answer now.
            try Task.checkCancellation()
            switch await policy.evaluate(message) {
            case .allow:
                break
            case .needsConsent(let current) where current == disclosure:
                break
            case .deny(let violation):
                throw OutboxError.denied(violation)
            case .needsConsent:
                throw OutboxError.policyChangedDuringConsent
            }
        }

        try Task.checkCancellation()

        // The ledger (ADR 0021): nothing goes out in a conversation that has
        // ended, and an answer first reserves every candidate it covers (the
        // query's and anything it returns), so no friend learns about more
        // than the limit in one conversation, whatever the skill remembers.
        // A ledger that cannot answer stops the send.
        if let ledger {
            guard try await !ledger.isRetired(conversation) else { throw OutboxError.conversationRetired }
            if case .answer(let answer) = body, let acceptable = answer.acceptable {
                guard let query = context.answering, query.issue == answer.issue else { throw OutboxError.answerWithoutItsQuery }
                let covered = Array(Set(query.candidates.candidates).union(acceptable.candidates))
                guard try await ledger.reserve(covered, issue: query.issue, to: recipient, in: conversation) else {
                    throw OutboxError.answerLimitReached
                }
            }
        }

        // What the send discloses, for the observer before and after.
        let disclosed: [DisclosedItem]? = switch decision {
        case .needsConsent(let disclosure): disclosure.items
        case .allow: observer == nil ? nil : try? await policy.disclosedItems(for: message)
        case .deny: nil
        }
        try await observer?.outbox(willSend: draft, context: context, decision: decision, disclosed: disclosed)

        // Wait for this friend's earlier sends in the conversation, then
        // number and send. The caller's cancellation reaches the queued send.
        let key = SequenceKey(conversation: conversation, recipient: recipient)
        let previous = tails[key]
        let work = Task { () async throws -> Envelope in
            await previous?.value
            return try await self.numberAndSend(draft, key: key, message: message, cleared: decision)
        }
        tails[key] = Task { _ = await work.result }
        let envelope = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        await observer?.outbox(didSend: envelope, context: context, decision: decision, disclosed: disclosed)
        return envelope
    }

    /// Ends `conversation` for good (ADR 0021): records it in the ledger,
    /// then cancels every send of it still in flight, wherever it waits,
    /// including inside the transport's queue. Skills retire through here,
    /// not the ledger directly, so nothing already cleared slips out after.
    /// A send already sealed by the transport may still complete.
    public func retire(_ conversation: ConversationID) async throws {
        // Cancel first, so a ledger that fails to record the retirement
        // still leaves nothing of this conversation in flight.
        for work in inFlight[conversation]?.values ?? [:].values { work.cancel() }
        try await ledger?.retire(conversation)
    }

    /// Cancels every send still in flight, in every conversation. The app
    /// calls it after installing a stricter policy, so nothing cleared under
    /// the looser one leaves, wherever it waits (ADR 0021). Each skill sees
    /// its send cancelled and retries under the new policy if it still can.
    public func cancelInFlight() {
        for sends in inFlight.values {
            for work in sends.values { work.cancel() }
        }
    }

    /// Numbers `draft` and hands it to the transport. Runs once this key's
    /// earlier send has finished, so nothing else is numbered meanwhile.
    private func numberAndSend(_ draft: Envelope, key: SequenceKey, message: OutboundMessage, cleared: PolicyDecision) async throws -> Envelope {
        // Last point before anything leaves: a cancelled send never goes out,
        // including one cancelled while it waited, nothing goes out in a
        // conversation retired while this send waited, and the policy is
        // asked again, so a stricter setting installed while this send
        // waited stops it (ADR 0021).
        try Task.checkCancellation()
        if let ledger, try await ledger.isRetired(key.conversation) { throw OutboxError.conversationRetired }
        switch (cleared, await policy.evaluate(message)) {
        case (_, .allow): break
        case (.needsConsent(let approved), .needsConsent(let current)) where approved == current: break
        case (_, .deny(let violation)): throw OutboxError.denied(violation)
        default: throw OutboxError.policyChangedDuringConsent
        }
        try Task.checkCancellation()

        // Number the envelope now. A denied, declined, or cancelled send
        // consumes no number, so the friend sees no gap that says a send was
        // refused (review of PR #53). A conversation's first send to a
        // friend on this launch starts at the clock in milliseconds and above
        // anything the sequence store recorded, so a relaunch keeps rising
        // even if the clock moved back. The send time is now too: a consent
        // sheet can take longer than a receiver's age limit.
        let sentAt = now()
        let sequence: UInt64
        if let next = nextSequence[key] {
            sequence = next
        } else {
            let recorded = sequences?.highestSent(in: key.conversation, to: key.recipient)
            guard recorded != .max else { throw OutboxError.sequenceExhausted }
            sequence = max(Self.firstSequence(at: sentAt), recorded.map { $0 + 1 } ?? 0)
        }
        guard sequence != .max else { throw OutboxError.sequenceExhausted }
        try sequences?.recordSent(sequence, in: key.conversation, to: key.recipient)
        nextSequence[key] = sequence + 1
        let envelope = try Envelope(
            version: draft.version, id: draft.id, conversation: draft.conversation, sender: draft.sender, recipient: draft.recipient,
            sequence: sequence, sentAt: Timestamp(sentAt), body: draft.body, skill: draft.skill, mode: draft.mode, chainedFrom: draft.chainedFrom
        )
        do {
            try await transport.send(Frame(codec.encode(envelope)), to: key.recipient)
        } catch is CancellationError {
            // The transport dropped it before it left (a send queued behind
            // another, for example). Give the number back so the next send
            // takes it and the friend sees no gap. Nothing else on this key
            // was numbered meanwhile.
            nextSequence[key] = sequence
            throw CancellationError()
        }
        return envelope
    }
}
