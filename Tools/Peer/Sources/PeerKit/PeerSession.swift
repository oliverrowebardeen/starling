import Foundation
import StarlingCore
import StarlingFakes

/// The Mac side of a LocalP2P device test. Speaks exactly what the app's
/// Nearby screen speaks: the same service, envelope format, and
/// propose/accept exchange. It auto-accepts proposals and can send its own.
///
/// **Phase 0 tool: unauthenticated and unencrypted, like the transport.**
public actor PeerSession {
    public enum PeerError: Error, Equatable {
        case noSuchPeer(String)
    }

    public nonisolated let me: PeerID
    public nonisolated let log: AsyncStream<String>
    private let logContinuation: AsyncStream<String>.Continuation
    private let transport: any Transport
    private let outbox: Outbox
    private var inboxTask: Task<Void, Never>?
    private var pending: [MessageID: ContinuousClock.Instant] = [:]
    private let clock = ContinuousClock()

    /// Peers in the order they were found, for `send <number>`.
    public private(set) var peers: [PeerID] = []
    /// Round trips measured so far, for the checklist's min / median / max.
    public private(set) var roundTrips: [Duration] = []

    public init(transport: any Transport) {
        me = transport.localPeer
        self.transport = transport
        // Allow-all policy: this tool only ever sends the fixed sample proposal.
        outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved))
        (log, logContinuation) = AsyncStream.makeStream(of: String.self)
    }

    public func start() async throws {
        let events = Inbox(localPeer: me).events(from: transport)
        inboxTask = Task { [weak self] in
            for await event in events { await self?.handle(event) }
        }
        try await transport.start()
        emit("Listening as \(me.short)")
    }

    public func stop() async {
        await transport.stop()
        inboxTask?.cancel()
        emit("Stopped")
        logContinuation.finish()
    }

    /// Sends the sample proposal to a peer chosen by list number (1-based)
    /// or ID prefix.
    public func sendProposal(to selector: String) async throws {
        try await sendProposal(to: resolve(selector))
    }

    public func sendProposal(to peer: PeerID) async throws {
        let envelope = try await outbox.send(.propose(Self.sampleProposal()), to: peer, conversation: ConversationID())
        pending[envelope.id] = clock.now
        emit("-> propose to \(peer.short) (#\(envelope.sequence))")
    }

    public func describePeers() -> [String] {
        peers.enumerated().map { "\($0.offset + 1)) \($0.element.short)" }
    }

    func resolve(_ selector: String) throws -> PeerID {
        if let number = Int(selector), number >= 1, number <= peers.count { return peers[number - 1] }
        let matches = peers.filter { $0.hex.hasPrefix(selector.lowercased()) }
        guard !selector.isEmpty, matches.count == 1 else { throw PeerError.noSuchPeer(selector) }
        return matches[0]
    }

    private func handle(_ event: InboxEvent) async {
        switch event {
        case .peerAvailable(let peer):
            if !peers.contains(peer) { peers.append(peer) }
            emit("Found \(peer.short) (\(peers.firstIndex(of: peer)! + 1))")
        case .peerUnavailable(let peer):
            peers.removeAll { $0 == peer }
            emit("Lost \(peer.short)")
        case .dropped(let peer, let reason):
            emit("Dropped frame from \(peer.short): \(reason)")
        case .message(let envelope):
            await receive(envelope)
        }
    }

    private func receive(_ envelope: Envelope) async {
        switch envelope.body {
        case .propose(let proposal):
            emit("<- propose from \(envelope.sender.short): \(Self.describe(proposal.terms))")
            do {
                try await outbox.send(.accept(Acceptance(proposal: envelope.id, terms: proposal.terms)), to: envelope.sender, conversation: envelope.conversation)
                emit("-> accept to \(envelope.sender.short)")
            } catch {
                emit("Accept to \(envelope.sender.short) failed: \(error)")
            }
        case .accept(let acceptance):
            if let sentAt = pending.removeValue(forKey: acceptance.proposal) {
                let rtt = sentAt.duration(to: clock.now)
                roundTrips.append(rtt)
                emit("<- accept from \(envelope.sender.short), round trip \(String(format: "%.1f", Self.milliseconds(rtt))) ms")
            } else {
                emit("<- accept from \(envelope.sender.short)")
            }
        default:
            emit("<- \(envelope.body.kind.rawValue) from \(envelope.sender.short)")
        }
    }

    private func emit(_ line: String) {
        logContinuation.yield(line)
    }

    /// The same proposal the app's Nearby screen sends: boba tonight, $12.
    public static func sampleProposal(now: Date = Date()) throws -> Proposal {
        let start = Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: now) ?? now
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

    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }

    /// "N round trips: min / median / max" for the device checklist, or nil.
    public func roundTripSummary() -> String? {
        Self.summarize(roundTrips)
    }

    static func summarize(_ trips: [Duration]) -> String? {
        guard !trips.isEmpty else { return nil }
        let ms = trips.map(milliseconds).sorted()
        let middle = ms.count / 2
        let median = ms.count % 2 == 1 ? ms[middle] : (ms[middle - 1] + ms[middle]) / 2
        return String(format: "%d round trips: min %.1f ms, median %.1f ms, max %.1f ms", ms.count, ms[0], median, ms[ms.count - 1])
    }
}
