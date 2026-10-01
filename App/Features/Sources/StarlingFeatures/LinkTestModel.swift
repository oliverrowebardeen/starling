import Foundation
import Observation
import StarlingCore

/// The app's link layer and its test view: which peers are connected, a
/// round trip per peer, and the `hello` exchange that carries this agent's
/// card, which friends read to see which skills it runs (ADR 0010).
///
/// It rides the app's `Outbox` and gets events from the app's single Inbox
/// loop, so every link (lane E1's secure transports) is covered and only one
/// Wi-Fi Aware transport ever publishes. When a peer becomes available it
/// sends a `hello` with this agent's card, which is also the first round
/// trip. It answers a `hello` it did not start, once per conversation, and
/// never answers its own, so replies cannot loop. `hello` carries only the
/// agent card, which lane G's policy always allows.
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

    public private(set) var peers: [PeerRow] = []

    private let outbox: Outbox
    /// This agent's card, sent in every hello. The app replaces it when the
    /// owner switches a skill on or off.
    public var card: AgentCard
    private let name: @MainActor (PeerID) -> String?
    /// How long a round trip waits for its reply before it counts as lost.
    private let replyTimeout: Duration
    private let clock = ContinuousClock()
    /// Our hellos awaiting a reply: conversation to peer and start time.
    private var pending: [ConversationID: (peer: PeerID, start: ContinuousClock.Instant)] = [:]
    /// Conversations we started, so a reply to one is never answered.
    private var started: [ConversationID] = []
    /// Friends' hellos already answered, oldest first, bounded.
    private var answered: [ConversationID] = []

    public init(
        outbox: Outbox,
        card: AgentCard,
        name: @escaping @MainActor (PeerID) -> String?,
        replyTimeout: Duration = .seconds(10)
    ) {
        self.outbox = outbox
        self.card = card
        self.name = name
        self.replyTimeout = replyTimeout
    }

    /// Every event from the app's Inbox loop. Returns quickly: sends run on
    /// their own tasks.
    public func handle(_ event: InboxEvent) async {
        switch event {
        case .peerAvailable(let peer):
            update(peer) { $0.isConnected = true }
            Task { await self.ping(peer) }
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
            } else if !started.contains(envelope.conversation) && !answered.contains(envelope.conversation) {
                Self.remember(envelope.conversation, in: &answered)
                let outbox = outbox
                let card = card
                Task { _ = try? await outbox.send(.hello(card), to: envelope.sender, conversation: envelope.conversation) }
            }
        case .dropped:
            break
        }
    }

    /// Sends a hello and times the reply.
    public func ping(_ peer: PeerID) async {
        let conversation = ConversationID()
        Self.remember(conversation, in: &started)
        pending[conversation] = (peer, clock.now)
        update(peer) {
            $0.isWaiting = true
            $0.lastError = nil
        }
        do {
            try await outbox.send(.hello(card), to: peer, conversation: conversation)
            // Delivery is best effort and a reply can be lost (or dropped by
            // the Inbox, for example for clock skew), so stop waiting after a
            // while and let the owner try again.
            let timeout = replyTimeout
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.giveUp(on: conversation, after: timeout)
            }
        } catch {
            pending[conversation] = nil
            update(peer) {
                $0.isWaiting = false
                $0.lastError = SendFailureMessage.text(for: error) ?? String(describing: error)
            }
        }
    }

    private func giveUp(on conversation: ConversationID, after timeout: Duration) {
        guard let ping = pending.removeValue(forKey: conversation) else { return }
        let seconds = timeout.components.seconds
        update(ping.peer) {
            $0.isWaiting = false
            $0.lastError = seconds >= 1 ? "No reply within \(seconds) seconds." : "No reply in time."
        }
    }

    private static func remember(_ conversation: ConversationID, in list: inout [ConversationID]) {
        list.append(conversation)
        if list.count > 256 { list.removeFirst() }
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
