import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingNegotiation
import StarlingTransport
import Synchronization
import Testing

/// Retries every 20 ms and gives up on a step after 100 ms, so failure paths
/// finish quickly over a zero-latency hub.
let fastConfiguration = DownConfiguration(retryInterval: .milliseconds(20), maxAttempts: 5)
/// Real timers, but wall time pinned to `T.now` so slots are deterministic.
let pinnedClock = DownClock(now: { T.now }, sleep: { try await Task.sleep(for: $0) })

/// A `Transport` decorator that silently loses chosen outbound envelopes, as
/// a flaky link would after `send` returned.
actor LossyTransport: Transport {
    nonisolated let base: LoopbackTransport
    nonisolated var kind: TransportKind { base.kind }
    nonisolated var localPeer: PeerID { base.localPeer }
    nonisolated var events: AsyncStream<TransportEvent> { base.events }

    typealias Rule = @Sendable (_ envelope: Envelope, _ ownSends: Set<MessageID>) -> Bool
    private var rules: [(remaining: Int, matches: Rule)] = []
    private var ownSends: Set<MessageID> = []
    private(set) var lost: [Envelope] = []

    init(_ base: LoopbackTransport) { self.base = base }

    /// Loses the next `count` outbound envelopes that match.
    func lose(_ count: Int = .max, where matches: @escaping @Sendable (Envelope) -> Bool) {
        rules.append((count, { envelope, _ in matches(envelope) }))
    }

    /// Same, with the IDs of every envelope this phone sent before, lost or not.
    func lose(_ count: Int = .max, where matches: @escaping Rule) {
        rules.append((count, matches))
    }

    func clearRules() { rules = [] }

    func start() async throws { try await base.start() }
    func stop() async { await base.stop() }

    func send(_ frame: Frame, to peer: PeerID) async throws {
        if let envelope = try? EnvelopeCodec().decode(frame.bytes) {
            defer { ownSends.insert(envelope.id) }
            if let index = rules.firstIndex(where: { $0.remaining > 0 && $0.matches(envelope, ownSends) }) {
                rules[index].remaining -= 1
                lost.append(envelope)
                return
            }
        }
        try await base.send(frame, to: peer)
    }
}

/// Every envelope that crossed the hub, decoded.
actor Wire {
    private(set) var envelopes: [Envelope] = []
    func record(_ envelope: Envelope) { envelopes.append(envelope) }

    func sent(by peer: PeerID) -> [Envelope] { envelopes.filter { $0.sender == peer } }
    func kinds(from peer: PeerID) -> [MessageBody.Kind] { sent(by: peer).map(\.body.kind) }
    func haveSent(_ peers: [PeerID]) -> Bool { peers.allSatisfy { !sent(by: $0).isEmpty } }
}

actor EventLog {
    private(set) var events: [DownEvent] = []
    func append(_ event: DownEvent) { events.append(event) }

    var matches: [DownMatch] {
        events.compactMap { if case .matched(let match) = $0 { match } else { nil } }
    }

    /// Everything except progress: what would reach the owner as news.
    var notifications: [DownEvent] {
        events.filter { if case .checking = $0 { false } else { true } }
    }
}

/// One phone: transport, Outbox, Inbox, the app's Inbox loop, and a negotiator.
final class DownNode: Sendable {
    let name: String
    let key: IdentityPublicKey
    let transport: LossyTransport
    let store = InMemoryPairedPeerStore()
    let negotiator: DownNegotiator
    let log = EventLog()
    private let tasks: Mutex<[Task<Void, Never>]> = Mutex([])

    var id: PeerID { key.peerID }

    init(
        name: String, hub: LoopbackHub, model: any AgentModel, policy: any PolicyEngine, psi: any PSIProvider,
        consent: any ConsentProvider = ScriptedConsentProvider(.approved),
        clock: DownClock = pinnedClock, configuration: DownConfiguration = fastConfiguration
    ) {
        self.name = name
        key = try! IdentityPublicKey(bytes: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        transport = LossyTransport(LoopbackTransport(localPeer: key.peerID, hub: hub))
        let outbox = Outbox(transport: transport, policy: policy, consent: consent)
        negotiator = DownNegotiator(
            localPeer: key.peerID, outbox: outbox, pairedPeers: store, model: model, psi: psi,
            clock: clock, timeZone: TimeZone(identifier: "UTC")!, configuration: configuration
        )
    }

    func start() async throws {
        let inbox = Inbox(localPeer: id)
        let events = inbox.events(from: transport)
        // The app sees only the protocol.
        let service: any DownService = negotiator
        let log = log
        tasks.withLock {
            $0.append(Task { for await event in events { await service.handle(event) } })
            $0.append(Task { for await event in service.events { await log.append(event) } })
        }
        try await transport.start()
    }

    func stop() async {
        await negotiator.shutdown()
        await transport.stop()
        for task in tasks.withLock({ $0 }) { task.cancel() }
    }

    func pair(with other: DownNode) async throws {
        try await store.save(PairedPeer(publicKey: other.key, nickname: other.name, pairedAt: Timestamp(T.now)))
    }

    func want(
        time: [TimeSlot],
        liked: [String] = [],
        avoided: [String] = [],
        maxBudget: Int64? = nil,
        level: DownLevel = .down
    ) async throws {
        let rules = OwnerRules(constraints: try T.constraints(time: time, liked: liked, avoided: avoided, maxBudget: maxBudget))
        try await negotiator.setIntent(DownIntent(rules: rules, level: level, expiresAt: Timestamp(T.at(24))))
    }

    var isIdle: Bool {
        get async { await negotiator.conversations.isEmpty }
    }
}

/// N phones on one Loopback hub, every pair paired unless told otherwise.
final class DownWorld: Sendable {
    let hub: LoopbackHub
    let wire = Wire()
    let nodes: [DownNode]
    private let observer: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(
        _ names: [String],
        model: any AgentModel = ScriptedAgentModel(),
        policy: any PolicyEngine = FixedPolicyEngine(.allow),
        psi: any PSIProvider = InsecurePSIStub(),
        consent: any ConsentProvider = ScriptedConsentProvider(.approved),
        clock: DownClock = pinnedClock,
        configuration: DownConfiguration = fastConfiguration
    ) {
        let hub = LoopbackHub()
        self.hub = hub
        nodes = names.map {
            DownNode(name: $0, hub: hub, model: model, policy: policy, psi: psi, consent: consent, clock: clock, configuration: configuration)
        }
    }

    subscript(name: String) -> DownNode { nodes.first { $0.name == name }! }

    func start(pairAll: Bool = true) async throws {
        let deliveries = await hub.deliveries()
        let wire = wire
        observer.withLock {
            $0 = Task {
                for await delivery in deliveries {
                    if let envelope = try? EnvelopeCodec().decode(delivery.frame.bytes) { await wire.record(envelope) }
                }
            }
        }
        if pairAll {
            for a in nodes { for b in nodes where a !== b { try await a.pair(with: b) } }
        }
        for node in nodes { try await node.start() }
    }

    func stop() async {
        for node in nodes { await node.stop() }
        observer.withLock { $0?.cancel() }
    }

    /// Waits until no node has a conversation in progress, twice in a row
    /// with a pause between, so late retries have had their chance.
    func settle(timeout: Duration = .seconds(5)) async throws {
        try await eventually(timeout: timeout, "all idle") {
            for node in self.nodes where !(await node.isIdle) { return false }
            try? await Task.sleep(for: .milliseconds(150))
            for node in self.nodes where !(await node.isIdle) { return false }
            return true
        }
    }

    /// Every match any node reported is backed by the peer's own accept of
    /// the identical plan on the wire: the definition of "no false match".
    func expectNoFalseMatches() async {
        let envelopes = await wire.envelopes
        for node in nodes {
            for match in await node.log.matches {
                let backed = envelopes.contains { envelope in
                    guard envelope.sender == match.peer, envelope.recipient == node.id,
                          case .accept(let acceptance) = envelope.body,
                          let (plan, _) = DownProfile.split(acceptance.terms)
                    else { return false }
                    return plan == match.terms
                }
                #expect(backed, "\(node.name) matched without the peer's accept")
            }
        }
    }

    /// Checks every value each node put on the wire against that node's own
    /// hard limits. `rules` maps node name to its constraints.
    func expectNoViolations(_ rules: [String: ConstraintSet]) async {
        let utc = TimeZone(identifier: "UTC")!
        for (name, constraints) in rules {
            for envelope in await wire.sent(by: self[name].id) {
                let terms: Terms?
                switch envelope.body {
                case .propose(let proposal), .counter(let proposal): terms = proposal.terms
                case .accept(let acceptance): terms = DownProfile.split(acceptance.terms)?.plan
                case .query(let query): terms = try? Terms([query.issue: query.candidates])
                case .answer(let answer): terms = answer.acceptable.flatMap { try? Terms([answer.issue: $0]) }
                default: terms = nil
                }
                if let terms {
                    #expect(constraints.violations(of: terms, timeZone: utc).isEmpty, "\(name) sent \(terms)")
                }
            }
        }
    }
}

func eventually(timeout: Duration = .seconds(5), _ what: String, _ condition: @Sendable () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for \(what)")
}

func matchCounts(_ nodes: DownNode...) async -> [Int] {
    var counts: [Int] = []
    for node in nodes { counts.append(await node.log.matches.count) }
    return counts
}

/// Counts model calls across both phones of a test.
actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// A paired "friend" with no negotiator: the test scripts every message.
/// It has an Outbox and an Inbox like any phone, so its frames are well
/// formed; only their content is hostile.
final class RawPeer: Sendable {
    let key = try! IdentityPublicKey(bytes: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    let transport: LoopbackTransport
    let outbox: Outbox
    let inbox = Wire()
    private let loop: Mutex<Task<Void, Never>?> = Mutex(nil)

    var id: PeerID { key.peerID }

    init(hub: LoopbackHub) {
        transport = LoopbackTransport(localPeer: key.peerID, hub: hub)
        outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved))
    }

    func start() async throws {
        let events = Inbox(localPeer: id).events(from: transport)
        let inbox = inbox
        loop.withLock {
            $0 = Task {
                for await event in events {
                    if case .message(let envelope) = event { await inbox.record(envelope) }
                }
            }
        }
        try await transport.start()
    }

    func stop() async {
        await transport.stop()
        loop.withLock { $0?.cancel() }
    }

    @discardableResult
    func send(_ body: MessageBody, to peer: PeerID, in conversation: ConversationID) async throws -> Envelope {
        try await outbox.send(body, to: peer, conversation: conversation)
    }

    /// Waits for the next message of `kind`, after `skipping` earlier ones.
    func next(_ kind: MessageBody.Kind, skipping: Int = 0) async throws -> Envelope {
        try await eventually("a \(kind.rawValue)") { await self.inbox.envelopes.filter { $0.body.kind == kind }.count > skipping }
        return try #require(await inbox.envelopes.filter { $0.body.kind == kind }.dropFirst(skipping).first)
    }
}

/// A consent sheet the test answers when it chooses, like an owner who
/// looks at the phone later. Counts requests.
actor GatedConsentProvider: ConsentProvider {
    private var waiting: [CheckedContinuation<ConsentOutcome, Never>] = []
    private(set) var requests = 0

    func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        requests += 1
        return await withCheckedContinuation { waiting.append($0) }
    }

    var pending: Int { waiting.count }

    func answerAll(_ outcome: ConsentOutcome) {
        for continuation in waiting { continuation.resume(returning: outcome) }
        waiting = []
    }
}

/// Wall time a test can move forward. Timers stay real.
final class MovableClock: Sendable {
    private let current = Mutex(T.now)
    func set(_ date: Date) { current.withLock { $0 = date } }
    var clock: DownClock {
        DownClock(now: { [self] in self.current.withLock { $0 } }, sleep: { try await Task.sleep(for: $0) })
    }
}

/// Asks for consent on every message, with a disclosure that stays the same
/// when the Outbox re-checks after the owner answers.
func consentForEverything(_ kinds: Set<MessageBody.Kind> = Set(MessageBody.Kind.allCases)) -> FixedPolicyEngine {
    FixedPolicyEngine { message in
        guard kinds.contains(message.envelope.body.kind) else { return .allow }
        return .needsConsent(Disclosure(recipient: message.envelope.recipient, recipientModel: nil, items: []))
    }
}
