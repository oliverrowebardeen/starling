import Foundation
import Observation
import StarlingCore

/// Tests a link to nearby paired phones: which peers are connected, and a
/// round trip per peer. The Developer screen runs it over lane E2's
/// `WiFiAwareTransport` for E2's device checklist.
///
/// A round trip is a `hello` (the agent card only, which lane G's policy
/// always allows, so no owner data and no consent sheet) answered by a
/// `hello` in the same conversation. A phone answers a conversation once
/// and never answers its own pings, so replies cannot loop.
///
/// It owns its own `Inbox`, like the Phase 0 Nearby screen, until lane E1's
/// secure channel puts every transport behind the app's single Inbox loop.
@MainActor
@Observable
public final class LinkTestModel {
    public struct PeerRow: Identifiable, Hashable, Sendable {
        public let id: PeerID
        public var name: String
        public var isConnected: Bool
        public var isWaiting = false
        public var lastRoundTrip: Duration?
        public var lastError: String?
    }

    public enum Status: Hashable, Sendable {
        case idle, running
        case failed(String)
    }

    public private(set) var status = Status.idle
    public private(set) var peers: [PeerRow] = []
    public nonisolated var localPeer: PeerID { transport.localPeer }

    private let transport: any Transport
    private let outbox: Outbox
    private let card: AgentCard
    private let name: @MainActor (PeerID) -> String?
    private let clock = ContinuousClock()
    /// Our pings awaiting a reply: conversation to peer and start time.
    private var pending: [ConversationID: (peer: PeerID, start: ContinuousClock.Instant)] = [:]
    /// Friends' pings already answered, oldest first, bounded.
    private var answered: [ConversationID] = []
    private var loop: Task<Void, Never>?

    public init(
        transport: any Transport,
        policy: any PolicyEngine,
        consent: any ConsentProvider,
        observer: (any OutboxObserver)?,
        card: AgentCard,
        name: @escaping @MainActor (PeerID) -> String?
    ) {
        self.transport = transport
        outbox = Outbox(transport: transport, policy: policy, consent: consent, observer: observer)
        self.card = card
        self.name = name
    }

    public func start() async {
        guard status != .running, loop == nil else { return }
        let events = Inbox(localPeer: transport.localPeer).events(from: transport)
        loop = Task { [weak self] in
            for await event in events { await self?.handle(event) }
        }
        do {
            try await transport.start()
            status = .running
        } catch {
            status = .failed(String(describing: error))
        }
    }

    public func stop() async {
        await transport.stop()
        loop?.cancel()
        loop = nil
        pending.removeAll()
        status = .idle
    }

    public func ping(_ peer: PeerID) async {
        let conversation = ConversationID()
        pending[conversation] = (peer, clock.now)
        update(peer) {
            $0.isWaiting = true
            $0.lastError = nil
        }
        do {
            try await outbox.send(.hello(card), to: peer, conversation: conversation)
        } catch {
            pending[conversation] = nil
            update(peer) {
                $0.isWaiting = false
                $0.lastError = SendFailureMessage.text(for: error) ?? String(describing: error)
            }
        }
    }

    func handle(_ event: InboxEvent) async {
        switch event {
        case .peerAvailable(let peer):
            update(peer) { $0.isConnected = true }
        case .peerUnavailable(let peer):
            update(peer) {
                $0.isConnected = false
                $0.isWaiting = false
            }
        case .message(let envelope):
            guard case .hello = envelope.body else { return }
            if let ping = pending.removeValue(forKey: envelope.conversation), ping.peer == envelope.sender {
                let elapsed = ping.start.duration(to: clock.now)
                update(envelope.sender) {
                    $0.isWaiting = false
                    $0.lastRoundTrip = elapsed
                }
            } else if !answered.contains(envelope.conversation) {
                answered.append(envelope.conversation)
                if answered.count > 256 { answered.removeFirst() }
                _ = try? await outbox.send(.hello(card), to: envelope.sender, conversation: envelope.conversation)
            }
        case .dropped:
            break
        }
    }

    private func update(_ peer: PeerID, _ change: (inout PeerRow) -> Void) {
        if let index = peers.firstIndex(where: { $0.id == peer }) {
            change(&peers[index])
        } else {
            var row = PeerRow(id: peer, name: name(peer) ?? peer.short, isConnected: false)
            change(&row)
            peers.append(row)
        }
    }
}
