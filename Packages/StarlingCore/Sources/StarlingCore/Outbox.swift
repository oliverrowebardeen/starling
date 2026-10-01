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
/// `Outbox` calls the method with `disclosed`, which by default forwards to
/// the three-argument one; implement it as well when you need the items.
public protocol OutboxObserver: Sendable {
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async
    /// - Parameter disclosed: What the send disclosed: the consent sheet's
    ///   items, or for a send allowed without a sheet the policy's own list.
    ///   Nil when the policy could not say.
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async
}

extension OutboxObserver {
    public func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async {
        await outbox(didSend: envelope, context: context, decision: decision)
    }
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

        // Last point before anything leaves: a cancelled send never goes out,
        // including one cancelled while the re-check above was running.
        try Task.checkCancellation()

        // Number the envelope now, with no suspension before the transport
        // takes it. A denied, declined, or cancelled send consumes no number,
        // so the friend sees no gap that says a send was refused (review of
        // PR #53). A conversation's first send on this launch starts at the
        // clock in milliseconds, so a relaunched app never reuses a number
        // the friend has seen. The send time is now too: a consent sheet can
        // take longer than a receiver's age limit.
        let sentAt = now()
        let sequence = nextSequence[conversation] ?? Self.firstSequence(at: sentAt)
        nextSequence[conversation] = sequence + 1
        let envelope = try Envelope(
            version: draft.version, id: draft.id, conversation: conversation, sender: draft.sender, recipient: recipient,
            sequence: sequence, sentAt: Timestamp(sentAt), body: body, skill: skill, mode: mode, chainedFrom: chainedFrom
        )
        try await transport.send(Frame(codec.encode(envelope)), to: recipient)
        if let observer {
            let disclosed: [DisclosedItem]? = switch decision {
            case .needsConsent(let disclosure): disclosure.items
            case .allow: try? await policy.disclosedItems(for: message)
            case .deny: nil
            }
            await observer.outbox(didSend: envelope, context: context, decision: decision, disclosed: disclosed)
        }
        return envelope
    }
}
