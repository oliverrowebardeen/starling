import Foundation
import Observation
import StarlingCore
import StarlingFakes
import StarlingLocalP2P

/// Drives the Phase 0 LocalP2P spike: discover nearby phones, send a typed
/// proposal, auto-accept incoming proposals, and time the round trip.
@MainActor
@Observable
final class NearbySession {
    struct LogLine: Identifiable {
        let id = UUID()
        let time = Date()
        let text: String
    }

    enum Status: Equatable {
        case idle, running
        case failed(String)
    }

    let me = PeerID.random()
    private(set) var status = Status.idle
    private(set) var peers: [PeerID] = []
    private(set) var log: [LogLine] = []

    private var transport: LocalP2PTransport?
    private var outbox: Outbox?
    private var inboxTask: Task<Void, Never>?
    /// Start times by conversation, which exists before sending, so an
    /// accept that arrives while `send` is still suspended is still timed.
    private var pending: [ConversationID: ContinuousClock.Instant] = [:]
    private let clock = ContinuousClock()

    func start() async {
        guard status != .running else { return }
        let transport = LocalP2PTransport(localPeer: me)
        // Phase 0: allow-all policy. The Policy lane replaces this in Phase 1.
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved))
        let events = Inbox(localPeer: me).events(from: transport)
        self.transport = transport
        self.outbox = outbox
        inboxTask = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
        do {
            try await transport.start()
            status = .running
            append("Listening as \(me.short) on \(transport.serviceName)")
        } catch {
            status = .failed(String(describing: error))
        }
    }

    func stop() async {
        await transport?.stop()
        inboxTask?.cancel()
        transport = nil
        outbox = nil
        peers = []
        status = .idle
        append("Stopped")
    }

    func sendProposal(to peer: PeerID) async {
        guard let outbox else { return }
        let conversation = ConversationID()
        pending[conversation] = clock.now
        do {
            let envelope = try await outbox.send(.propose(Self.sampleProposal()), to: peer, conversation: conversation)
            append("-> propose to \(peer.short) (#\(envelope.sequence), \(try EnvelopeCodec().encode(envelope).count) bytes)")
        } catch {
            pending[conversation] = nil
            append("Send to \(peer.short) failed: \(error)")
        }
    }

    private func handle(_ event: InboxEvent) {
        switch event {
        case .peerAvailable(let peer):
            if !peers.contains(peer) { peers.append(peer) }
            append("Found \(peer.short)")
        case .peerUnavailable(let peer):
            peers.removeAll { $0 == peer }
            append("Lost \(peer.short)")
        case .dropped(let peer, let reason):
            append("Dropped frame from \(peer.short): \(reason)")
        case .message(let envelope):
            receive(envelope)
        }
    }

    private func receive(_ envelope: Envelope) {
        switch envelope.body {
        case .propose(let proposal):
            append("<- propose from \(envelope.sender.short): \(Self.describe(proposal.terms))")
            let reply = MessageBody.accept(Acceptance(proposal: envelope.id, terms: proposal.terms))
            Task { [outbox] in
                _ = try? await outbox?.send(reply, to: envelope.sender, conversation: envelope.conversation)
            }
        case .accept:
            if let sentAt = pending.removeValue(forKey: envelope.conversation) {
                let rtt = sentAt.duration(to: clock.now)
                append("<- accept from \(envelope.sender.short), round trip \(rtt.formatted(.units(allowed: [.milliseconds])))")
            } else {
                append("<- accept from \(envelope.sender.short)")
            }
        default:
            append("<- \(envelope.body.kind.rawValue) from \(envelope.sender.short)")
        }
    }

    private func append(_ text: String) {
        log.insert(LogLine(text: text), at: 0)
        if log.count > 200 { log.removeLast() }
    }

    static func sampleProposal() throws -> Proposal {
        let start = Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: Date()) ?? Date()
        return try Proposal(round: 0, terms: Terms([
            .time: .slots([try TimeSlot(start: start, end: start.addingTimeInterval(2 * 3600))]),
            .activity: .keywords([try Keyword("boba")]),
            .budget: .amount(try MoneyAmount(minorUnits: 1200)),
        ]))
    }

    static func describe(_ terms: Terms) -> String {
        terms.values.keys.sorted().map { key -> String in
            switch terms.values[key]! {
            case .slots(let slots): "\(key) \(slots.map { $0.start.formatted(date: .omitted, time: .shortened) }.joined(separator: ","))"
            case .keywords(let words): "\(key) \(words.map(\.value).joined(separator: ","))"
            case .amount(let amount): "\(key) \(amount.minorUnits / 100) \(amount.currency)"
            case .flag(let flag): "\(key) \(flag)"
            case .count(let count): "\(key) \(count)"
            }
        }.joined(separator: "; ")
    }
}
