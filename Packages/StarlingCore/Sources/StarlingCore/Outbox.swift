import Foundation

public enum OutboxError: Error, Hashable, Sendable {
    case denied(PolicyViolation)
    case consentDeclined
    /// The policy's answer changed while the owner was deciding (rules
    /// edited, peer trust removed); nothing was sent (v1.1).
    case policyChangedDuringConsent
}

/// Told about every envelope the transport accepted, for example to keep an
/// audit log. Never told about denied, declined, cancelled, or failed sends.
public protocol OutboxObserver: Sendable {
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async
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
    private let now: @Sendable () -> Date
    private var nextSequence: [ConversationID: UInt64] = [:]

    public init(
        transport: any Transport,
        policy: any PolicyEngine,
        consent: any ConsentProvider,
        codec: EnvelopeCodec = EnvelopeCodec(),
        observer: (any OutboxObserver)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.policy = policy
        self.consent = consent
        self.codec = codec
        self.observer = observer
        self.now = now
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
        chainedFrom: ConversationID? = nil
    ) async throws -> Envelope {
        // Reserve the sequence number before any suspension point so two
        // concurrent sends never share one. Gaps are fine; Inbox only
        // requires uniqueness within its replay window.
        let sequence = nextSequence[conversation, default: 0]
        nextSequence[conversation] = sequence + 1

        let envelope = try Envelope(
            conversation: conversation,
            sender: transport.localPeer,
            recipient: recipient,
            sequence: sequence,
            sentAt: Timestamp(now()),
            body: body,
            skill: skill,
            chainedFrom: chainedFrom
        )

        let message = OutboundMessage(envelope: envelope, recipientCard: recipientCard, transport: transport.kind, context: context)
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

        // Last point before anything leaves: a cancelled send never goes out,
        // including one cancelled while the re-check above was running.
        try Task.checkCancellation()
        try await transport.send(Frame(codec.encode(envelope)), to: recipient)
        await observer?.outbox(didSend: envelope, context: context, decision: decision)
        return envelope
    }
}
