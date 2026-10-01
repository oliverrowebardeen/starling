import Foundation
import SimulatorKit
import StarlingCore
import StarlingFakes
import StarlingNegotiation
import StarlingPolicy
import StarlingTransport
import Testing

enum IntegrationFixtures {
    static let now = Date(timeIntervalSince1970: 1_790_967_600)
    static let utc = TimeZone(secondsFromGMT: 0)!
    static let expiry = now.addingTimeInterval(6 * 3600)
    static let configuration = DownConfiguration(retryInterval: .milliseconds(100), maxAttempts: 4)
    static let clock = DownClock(now: { now }, sleep: { try await Task.sleep(for: $0) })

    static func slot(_ start: Int = 1, _ end: Int = 3) throws -> TimeSlot {
        try TimeSlot(start: now.addingTimeInterval(Double(start * 3600)), end: now.addingTimeInterval(Double(end * 3600)))
    }

    static func rules(
        time: TimeSlot? = nil, liked: [String] = ["food"], avoided: [String] = [],
        budget: Int64 = 1500, never: IssueKey? = nil, ask: IssueKey? = nil
    ) throws -> OwnerRules {
        let limits = try ConstraintSet([
            .time: [Constraint(.within([time ?? slot()]))],
            .activity: [Constraint(.prefers(liked: liked.map { try Keyword($0) }, avoided: avoided.map { try Keyword($0) }))],
            .budget: [Constraint(.atMost(MoneyAmount(minorUnits: budget)))],
        ])
        let disclosure = [IssueKey.time, .activity, .budget, .downLevel, .place].map { issue in
            DisclosureRule(issue: issue, action: issue == never ? .never : issue == ask ? .askEachTime : .allowOnDevicePeers)
        }
        return OwnerRules(constraints: limits, disclosure: disclosure)
    }

    static func plan(time: TimeSlot? = nil, activity: [String]? = ["food"], budget: Int64 = 1000) throws -> Terms {
        var values: [IssueKey: IssueValue] = try [.time: .slots([time ?? slot()]), .budget: .amount(MoneyAmount(minorUnits: budget))]
        if let activity { values[.activity] = .keywords(try activity.map { try Keyword($0) }) }
        return try Terms(values)
    }

    static func withLevel(_ plan: Terms, _ level: DownLevel = .down) throws -> Terms {
        var values = plan.values
        values[.downLevel] = .keywords([try Keyword(level.rawValue)])
        return try Terms(values)
    }

    static func planOnly(_ terms: Terms) throws -> Terms {
        var values = terms.values
        values[.downLevel] = nil
        return try Terms(values)
    }

    static func mentionsLevel(_ body: MessageBody) -> Bool {
        switch body {
        case .propose(let proposal), .counter(let proposal): proposal.terms[.downLevel] != nil
        case .accept(let acceptance): acceptance.terms[.downLevel] != nil
        case .query(let query): query.issue == .downLevel
        case .answer(let answer): answer.issue == .downLevel
        default: false
        }
    }
}

/// Observes real policy decisions without replacing any of its logic.
actor PolicyTrace: PolicyEngine {
    struct Entry: Sendable { let message: OutboundMessage; let decision: PolicyDecision }
    let implementation: DeterministicPolicyEngine
    private(set) var entries: [Entry] = []

    init(_ implementation: DeterministicPolicyEngine) { self.implementation = implementation }
    func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        let decision = await implementation.evaluate(message)
        entries.append(Entry(message: message, decision: decision))
        return decision
    }
}

actor ControlledConsent: ConsentProvider {
    private(set) var requests: [Disclosure] = []
    private var waiting: [CheckedContinuation<ConsentOutcome, Never>] = []
    private let holdIssue: IssueKey
    init(holding issue: IssueKey) { holdIssue = issue }
    func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        requests.append(disclosure)
        if disclosure.items.contains(where: { $0.issue == holdIssue }) {
            return await withCheckedContinuation { waiting.append($0) }
        }
        return .approved
    }
    var pending: Int { waiting.count }
    func resolve(_ outcome: ConsentOutcome) {
        let pending = waiting
        waiting = []
        for waiter in pending { waiter.resume(returning: outcome) }
    }
}

struct NodeConfiguration: Sendable {
    let rules: OwnerRules
    var model: any AgentModel = ScriptedAgentModel()
    var consent: any ConsentProvider = ScriptedConsentProvider(.approved)
    var locality: ModelLocality = .onDevice
    var onlyOnDevice = false
    var scriptedPeer = false
}

/// Public APIs only: every feature receives InboxEvent and sends via Outbox.
/// Paired records are test fixtures, not authentication of the bare link.
actor IntegratedNode {
    nonisolated let key: IdentityPublicKey
    nonisolated var id: PeerID { key.peerID }
    nonisolated let store = InMemoryPairedPeerStore()
    nonisolated let policy: PolicyTrace
    nonisolated let audit: InMemoryAuditLog
    nonisolated let outbox: Outbox
    nonisolated let down: DownNegotiator?
    nonisolated let configuration: NodeConfiguration
    private let transport: LoopbackTransport
    private var loops: [Task<Void, Never>] = []
    private(set) var received: [Envelope] = []
    private(set) var dropped: [InboxDrop] = []
    private(set) var events: [DownEvent] = []
    private(set) var cards: [PeerID: AgentCard] = [:]

    init(index: UInt8, hub: LoopbackHub, configuration: NodeConfiguration) throws {
        self.configuration = configuration
        key = try IdentityPublicKey(bytes: Data(repeating: index, count: 32))
        transport = LoopbackTransport(localPeer: key.peerID, hub: hub)
        audit = try InMemoryAuditLog(now: { IntegrationFixtures.now })
        policy = PolicyTrace(DeterministicPolicyEngine(ownerRules: configuration.rules,
                            onlyOnDeviceAgents: configuration.onlyOnDevice, pairedPeers: store))
        outbox = Outbox(transport: transport, policy: policy, consent: configuration.consent,
                        observer: audit, now: { IntegrationFixtures.now })
        down = configuration.scriptedPeer ? nil : DownNegotiator(
            localPeer: key.peerID, outbox: outbox, pairedPeers: store, model: configuration.model,
            psi: InsecurePSIStub(), clock: IntegrationFixtures.clock, timeZone: IntegrationFixtures.utc,
            configuration: IntegrationFixtures.configuration
        )
    }

    func start() async throws {
        let inboxEvents = Inbox(localPeer: id, now: { IntegrationFixtures.now }).events(from: transport)
        loops.append(Task { [weak self] in
            for await event in inboxEvents { await self?.receive(event) }
        })
        if let down {
            loops.append(Task { [weak self] in
                for await event in down.events { await self?.record(event) }
            })
        }
        try await transport.start()
    }

    private func receive(_ event: InboxEvent) async {
        switch event {
        case .message(let envelope):
            received.append(envelope)
            if case .hello(let card) = envelope.body { cards[envelope.sender] = card }
        case .dropped(_, let reason): dropped.append(reason)
        default: break
        }
        await down?.handle(event)
    }
    private func record(_ event: DownEvent) { events.append(event) }
    var matches: [DownMatch] { events.compactMap { if case .matched(let match) = $0 { match } else { nil } } }

    func stop() async {
        await down?.shutdown()
        if let consent = configuration.consent as? ControlledConsent { await consent.resolve(.declined) }
        await transport.stop()
        for loop in loops { loop.cancel(); await loop.value }
        loops = []
    }

    func want(_ level: DownLevel = .down) async throws {
        try await down?.setIntent(DownIntent(rules: configuration.rules, level: level, expiresAt: Timestamp(IntegrationFixtures.expiry)))
    }

    @discardableResult
    func send(_ body: MessageBody, to recipient: PeerID, conversation: ConversationID = ConversationID(),
              context: OutboundContext = .empty) async throws -> Envelope {
        try await outbox.send(body, to: recipient, conversation: conversation, recipientCard: cards[recipient], context: context)
    }

    func next(_ kind: MessageBody.Kind, conversation: ConversationID? = nil, after count: Int = 0) async throws -> Envelope {
        try await Simulation.eventually("peer receives \(kind)") {
            await self.received.filter { $0.body.kind == kind && (conversation == nil || $0.conversation == conversation) }.count > count
        }
        return try #require(received.filter { $0.body.kind == kind && (conversation == nil || $0.conversation == conversation) }.dropFirst(count).first)
    }
}

actor IntegratedWire {
    private(set) var envelopes: [Envelope] = []
    func append(_ envelope: Envelope) { envelopes.append(envelope) }
    func sent(by id: PeerID) -> [Envelope] { envelopes.filter { $0.sender == id && $0.body.kind != .hello } }
}

actor IntegratedWorld {
    nonisolated let hub: LoopbackHub
    nonisolated let nodes: [IntegratedNode]
    nonisolated let wire = IntegratedWire()
    private var observer: Task<Void, Never>?

    init(_ configurations: [NodeConfiguration]) throws {
        let hub = LoopbackHub()
        self.hub = hub
        nodes = try configurations.enumerated().map { try IntegratedNode(index: UInt8($0.offset + 1), hub: hub, configuration: $0.element) }
    }

    func pair(_ a: IntegratedNode, _ b: IntegratedNode) async throws {
        try await a.store.save(PairedPeer(publicKey: b.key, nickname: "fixture", pairedAt: Timestamp(IntegrationFixtures.now)))
        try await b.store.save(PairedPeer(publicKey: a.key, nickname: "fixture", pairedAt: Timestamp(IntegrationFixtures.now)))
    }

    func start(paired: Bool = true) async throws {
        let deliveries = await hub.deliveries()
        observer = Task { [wire] in
            for await delivery in deliveries {
                if let envelope = try? EnvelopeCodec().decode(delivery.frame.bytes) { await wire.append(envelope) }
            }
        }
        if paired {
            for (index, a) in nodes.enumerated() { for b in nodes.dropFirst(index + 1) { try await pair(a, b) } }
        }
        for node in nodes { try await node.start() }
        for a in nodes { for b in nodes where a.id != b.id {
            try await a.send(.hello(AgentCard(model: a.configuration.locality, capabilities: [.down, .psi])), to: b.id)
        } }
        for node in nodes {
            try await Simulation.eventually("all agent cards") { await node.cards.count == self.nodes.count - 1 }
        }
    }

    func stop() async {
        for node in nodes { await node.stop() }
        observer?.cancel()
        await observer?.value
    }

    /// More than the fixed details deadline (2 * 4 * 100 ms). Tests wait
    /// for the triggering frame or policy decision before calling this.
    func waitForTimeouts() async throws { try await Task.sleep(for: .seconds(1)) }

    func expectSilence(_ node: IntegratedNode) async {
        #expect(await node.matches.isEmpty)
        #expect(await wire.sent(by: node.id).allSatisfy { !IntegrationFixtures.mentionsLevel($0.body) })
    }

    func expectAudited(_ node: IntegratedNode) async throws {
        try await Simulation.eventually("successful sends reach audit observer") {
            let sent = await self.wire.envelopes.filter { $0.sender == node.id }
            let entries = await node.audit.entries()
            return Set(sent.map(\.id)) == Set(entries.map(\.message))
        }
    }

    func expectSafeMatches() async throws {
        for node in nodes { try await expectAudited(node) }
        let wire = await wire.envelopes
        for node in nodes {
            for match in await node.matches {
                #expect(node.configuration.rules.constraints.violations(of: match.terms, timeZone: IntegrationFixtures.utc).isEmpty)
                #expect(wire.contains { envelope in
                    guard envelope.sender == match.peer, envelope.recipient == node.id,
                          case .accept(let acceptance) = envelope.body else { return false }
                    return (try? IntegrationFixtures.planOnly(acceptance.terms)) == match.terms
                }, "Every match needs the peer's acceptance of the same plan")
            }
        }
    }
}

func withIntegratedWorld(_ configurations: [NodeConfiguration], paired: Bool = true,
                         _ body: (IntegratedWorld) async throws -> Void) async throws {
    let world = try IntegratedWorld(configurations)
    do { try await world.start(paired: paired); try await body(world); await world.stop() }
    catch { await world.stop(); throw error }
}
