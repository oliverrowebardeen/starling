import Foundation
import StarlingCore
import StarlingIdentity
import StarlingTransport

/// Decides how a simulated agent reacts to messages other than `hello`.
public protocol AgentBehavior: Sendable {
    func respond(to envelope: Envelope, in agent: SimulatedAgent) async
}

/// Ignores everything. The default.
public struct PassiveBehavior: AgentBehavior {
    public init() {}
    public func respond(to envelope: Envelope, in agent: SimulatedAgent) async {}
}

/// Accepts any proposal or counter with the same terms. Useful for exercising
/// message flow; real negotiation logic belongs to StarlingNegotiation.
public struct AcceptEverything: AgentBehavior {
    public init() {}
    public func respond(to envelope: Envelope, in agent: SimulatedAgent) async {
        switch envelope.body {
        case .propose(let proposal), .counter(let proposal):
            _ = try? await agent.send(
                .accept(Acceptance(proposal: envelope.id, terms: proposal.terms)),
                to: envelope.sender,
                conversation: envelope.conversation
            )
        default:
            break
        }
    }
}

/// One line of an agent's log.
public struct LogEntry: Hashable, Sendable, CustomStringConvertible {
    public enum Event: Hashable, Sendable {
        case peerAvailable(PeerID)
        case peerUnavailable(PeerID)
        case received(Envelope)
        case dropped(from: PeerID, reason: InboxDrop)
        case sent(Envelope)
        case sendFailed(to: PeerID, error: String)
    }

    public let agent: String
    public let event: Event

    public var description: String {
        switch event {
        case .peerAvailable(let peer): "\(agent): sees \(peer.short)"
        case .peerUnavailable(let peer): "\(agent): lost \(peer.short)"
        case .received(let envelope): "\(agent): <- \(envelope.body.kind.rawValue) from \(envelope.sender.short) #\(envelope.sequence)"
        case .dropped(let peer, let reason): "\(agent): DROPPED frame from \(peer.short): \(reason)"
        case .sent(let envelope): "\(agent): -> \(envelope.body.kind.rawValue) to \(envelope.recipient.short) #\(envelope.sequence)"
        case .sendFailed(let peer, let error): "\(agent): send to \(peer.short) failed: \(error)"
        }
    }
}

/// A full Starling stack over Loopback: transport, Outbox, Inbox, and a
/// behavior. Says `hello` to every peer it sees and records their cards.
public actor SimulatedAgent {
    public nonisolated let name: String
    public nonisolated let card: AgentCard
    public nonisolated var id: PeerID { transport.localPeer }
    /// The secure channel under this agent's Outbox and Inbox, when the
    /// simulation uses `LinkSecurity.secureChannel`. Scenarios read its
    /// `status(of:)` to see frames it dropped before the Inbox.
    public nonisolated let secureTransport: SecureTransport?

    nonisolated let transport: any Transport
    private let outbox: Outbox
    private let inbox: Inbox
    private let behavior: any AgentBehavior
    private var loop: Task<Void, Never>?

    public private(set) var peerCards: [PeerID: AgentCard] = [:]
    public private(set) var log: [LogEntry] = []

    /// - Parameters:
    ///   - transport: Bare Loopback, or `secureTransport` itself.
    ///   - secureTransport: Set when `transport` is a secure channel.
    init(
        name: String,
        transport: any Transport,
        secureTransport: SecureTransport? = nil,
        card: AgentCard,
        behavior: any AgentBehavior,
        policy: any PolicyEngine,
        consent: any ConsentProvider,
        now: @escaping @Sendable () -> Date
    ) {
        self.name = name
        self.card = card
        self.behavior = behavior
        self.transport = transport
        self.secureTransport = secureTransport
        outbox = Outbox(transport: transport, policy: policy, consent: consent, now: now)
        inbox = Inbox(localPeer: transport.localPeer, now: now)
    }

    public var received: [Envelope] {
        log.compactMap { if case .received(let envelope) = $0.event { envelope } else { nil } }
    }

    public var dropped: [InboxDrop] {
        log.compactMap { if case .dropped(_, let reason) = $0.event { reason } else { nil } }
    }

    func start() async throws {
        let events = inbox.events(from: transport)
        loop = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
        try await transport.start()
    }

    func stop() async {
        await transport.stop()
        await loop?.value
    }

    /// Sends through this agent's Outbox, so policy applies.
    @discardableResult
    public func send(_ body: MessageBody, to peer: PeerID, conversation: ConversationID = ConversationID()) async throws -> Envelope {
        do {
            let envelope = try await outbox.send(body, to: peer, conversation: conversation, recipientCard: peerCards[peer])
            log.append(LogEntry(agent: name, event: .sent(envelope)))
            return envelope
        } catch {
            log.append(LogEntry(agent: name, event: .sendFailed(to: peer, error: String(describing: error))))
            throw error
        }
    }

    private func handle(_ event: InboxEvent) async {
        switch event {
        case .peerAvailable(let peer):
            log.append(LogEntry(agent: name, event: .peerAvailable(peer)))
            _ = try? await send(.hello(card), to: peer)
        case .peerUnavailable(let peer):
            log.append(LogEntry(agent: name, event: .peerUnavailable(peer)))
        case .dropped(let peer, let reason):
            log.append(LogEntry(agent: name, event: .dropped(from: peer, reason: reason)))
        case .message(let envelope):
            log.append(LogEntry(agent: name, event: .received(envelope)))
            if case .hello(let card) = envelope.body {
                peerCards[envelope.sender] = card
            } else {
                await behavior.respond(to: envelope, in: self)
            }
        }
    }
}
