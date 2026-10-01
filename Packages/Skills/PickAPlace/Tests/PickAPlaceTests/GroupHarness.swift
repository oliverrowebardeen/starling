import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingTransport
import Synchronization
import Testing

/// Retries every 20 ms; windows short enough for silent friends to time out
/// quickly, long enough for a loaded machine.
let fastConfiguration = PickAPlaceConfiguration(
    retryInterval: .milliseconds(20), maxRetryInterval: .milliseconds(80),
    answerWindow: .seconds(3), confirmWindow: .seconds(3)
)

let utc = TimeZone(identifier: "UTC")!

/// Waits until `condition` holds, polling every 10 ms, for up to `seconds`.
func eventually(_ seconds: Double = 5, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// A `Transport` decorator that silently loses chosen outbound envelopes, as
/// a flaky link would after `send` returned.
actor LossyTransport: Transport {
    nonisolated let base: LoopbackTransport
    nonisolated var kind: TransportKind { base.kind }
    nonisolated var localPeer: PeerID { base.localPeer }
    nonisolated var events: AsyncStream<TransportEvent> { base.events }
    private var rules: [(remaining: Int, matches: @Sendable (Envelope) -> Bool)] = []
    private(set) var lost: [Envelope] = []

    init(_ base: LoopbackTransport) { self.base = base }

    func lose(_ count: Int, where matches: @escaping @Sendable (Envelope) -> Bool) { rules.append((count, matches)) }
    func clearRules() { rules = [] }

    func start() async throws { try await base.start() }
    func stop() async { await base.stop() }

    func send(_ frame: Frame, to peer: PeerID) async throws {
        if let envelope = try? EnvelopeCodec().decode(frame.bytes),
           let index = rules.firstIndex(where: { $0.remaining > 0 && $0.matches(envelope) }) {
            rules[index].remaining -= 1
            lost.append(envelope)
            return
        }
        try await base.send(frame, to: peer)
    }
}

/// Every envelope that crossed the hub, decoded.
actor Wire {
    private(set) var envelopes: [Envelope] = []
    func record(_ envelope: Envelope) { envelopes.append(envelope) }
    func sent(by peer: PeerID) -> [Envelope] { envelopes.filter { $0.sender == peer && $0.body.kind != .hello } }
    func sent(to peer: PeerID) -> [Envelope] { envelopes.filter { $0.recipient == peer && $0.body.kind != .hello } }

    /// Every issue key and value that crossed, from any body.
    var values: [(IssueKey, IssueValue)] {
        envelopes.flatMap { envelope -> [(IssueKey, IssueValue)] in
            switch envelope.body {
            case .propose(let p), .counter(let p): p.terms.values.map { ($0.key, $0.value) }
            case .accept(let a): a.terms.values.map { ($0.key, $0.value) }
            case .query(let q): [(q.issue, q.candidates)]
            case .answer(let a): a.acceptable.map { [(a.issue, $0)] } ?? []
            default: []
            }
        }
    }
}

/// Plays lane A's coordinator: applies every SkillEvent to an Interaction
/// with the real state machine, and records any it rejects. Its consent
/// sheet records consentNeeded and consentGiven as the shared sheet would.
actor Coordinator {
    private(set) var interactions: [InteractionID: Interaction] = [:]
    /// Every event the service reported, applied or not.
    private(set) var received: [SkillEvent] = []
    private(set) var rejected: [(SkillEvent, String)] = []
    private(set) var produced: [InteractionID: [Artifact]] = [:]
    private(set) var incoming: [(InteractionID, PeerID, ConversationID?)] = []
    private var nextConsent: UInt32 = 0

    func add(_ interaction: Interaction) { interactions[interaction.id] = interaction }

    func apply(_ event: SkillEvent) {
        received.append(event)
        switch event {
        case .incoming(let id, let conversation, let from, let chainedFrom):
            incoming.append((id, from, chainedFrom))
            interactions[id] = Interaction(id: id, conversation: conversation, skill: PickAPlaceSkill.ref, role: .invitee,
                                           participants: [from], createdAt: Timestamp(Date()))
        case .lifecycle(let id, let lifecycle):
            guard var interaction = interactions[id] else { rejected.append((event, "unknown interaction")); return }
            do {
                try interaction.apply(lifecycle, at: Timestamp(Date()))
                interactions[id] = interaction
            } catch {
                rejected.append((event, "\(error)"))
            }
        case .produced(let id, let artifact):
            produced[id, default: []].append(artifact)
            interactions[id]?.record(artifact)
        }
    }

    func interaction(conversation: ConversationID) -> Interaction? {
        interactions.values.first { $0.conversation == conversation }
    }

    func state(_ id: InteractionID) -> InteractionState? { interactions[id]?.state }

    func consentRequested(for conversation: ConversationID?) -> UInt32? {
        guard let conversation, var interaction = interaction(conversation: conversation) else { return nil }
        nextConsent += 1
        do {
            try interaction.apply(.consentNeeded(request: nextConsent), at: Timestamp(Date()))
            interactions[interaction.id] = interaction
            return nextConsent
        } catch {
            return nil
        }
    }

    /// Passing on the sheet is the owner's pass; the coordinator applies it.
    func consentDeclined(conversation: ConversationID?) {
        guard let conversation, var interaction = interaction(conversation: conversation) else { return }
        try? interaction.apply(.ownerPassed, at: Timestamp(Date()))
        interactions[interaction.id] = interaction
    }

    func consentApproved(_ request: UInt32, conversation: ConversationID?) {
        guard let conversation, var interaction = interaction(conversation: conversation) else { return }
        try? interaction.apply(.consentGiven(request: request), at: Timestamp(Date()))
        interactions[interaction.id] = interaction
    }
}

/// The shared consent sheet, answering with a fixed outcome.
final class CoordinatorConsent: ConsentProvider {
    let coordinator: Coordinator
    let outcome: ConsentOutcome
    /// When set, every sheet stays up until the gate opens.
    let gate: ConsentGate?
    let asked = Mutex<[Disclosure]>([])

    init(coordinator: Coordinator, outcome: ConsentOutcome, gate: ConsentGate? = nil) {
        self.coordinator = coordinator
        self.outcome = outcome
        self.gate = gate
    }

    func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        asked.withLock { $0.append(disclosure) }
        // A friend's request reaches the sheet right after `.incoming` is
        // emitted, possibly before the coordinator has applied it: wait for
        // the interaction, as lane A's sheet must.
        let coordinator = coordinator
        _ = await eventually(1) { await coordinator.interaction(conversation: disclosure.conversation ?? ConversationID()) != nil }
        let request = await coordinator.consentRequested(for: disclosure.conversation)
        await gate?.wait()
        if outcome == .approved, let request { await coordinator.consentApproved(request, conversation: disclosure.conversation) }
        if outcome == .declined { await coordinator.consentDeclined(conversation: disclosure.conversation) }
        return outcome
    }
}

/// Holds consent sheets open until the test opens it.
actor ConsentGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waiting = 0

    func wait() async {
        guard !isOpen else { return }
        waiting += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// One phone: transport, Outbox, Inbox loop, the service, and a coordinator.
final class Phone: Sendable {
    let name: String
    let key: IdentityPublicKey
    let transport: LossyTransport
    let store = InMemoryPairedPeerStore()
    let staged = StagedCandidates()
    /// Shared by every service this phone runs, as the app's log would be.
    let admissions = InMemoryRequestAdmissionLog()
    let coordinator = Coordinator()
    let consent: CoordinatorConsent
    let outbox: Outbox
    let card: AgentCard
    private let current: Mutex<PickAPlaceService>
    private let makeService: @Sendable () -> PickAPlaceService
    private let tasks = Mutex<[Task<Void, Never>]>([])

    /// The service now running; `restart()` replaces it.
    var service: PickAPlaceService { current.withLock { $0 } }

    var id: PeerID { key.peerID }

    init(
        _ name: String, hub: LoopbackHub, maps: FakeMaps, limits: ConstraintSet = .empty,
        ownerLimits: (@Sendable () async -> ConstraintSet)? = nil,
        policy: any PolicyEngine = FixedPolicyEngine(.allow), consent outcome: ConsentOutcome = .approved, gate: ConsentGate? = nil,
        skills: [SkillRef] = [PickAPlaceSkill.ref], model: ModelLocality = .onDevice, configuration: PickAPlaceConfiguration = fastConfiguration
    ) {
        self.name = name
        key = try! IdentityPublicKey(bytes: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        transport = LossyTransport(LoopbackTransport(localPeer: key.peerID, hub: hub))
        consent = CoordinatorConsent(coordinator: coordinator, outcome: outcome, gate: gate)
        outbox = Outbox(transport: transport, policy: policy, consent: consent)
        card = try! AgentCard(model: model, capabilities: [], skills: skills)
        let (peer, outbox, store, staged, admissions) = (key.peerID, outbox, store, staged, admissions)
        let readLimits: @Sendable () async -> ConstraintSet = ownerLimits ?? { limits }
        makeService = {
            PickAPlaceService(localPeer: peer, outbox: outbox, pairedPeers: store, candidates: staged, maps: maps,
                              ownerLimits: readLimits, admissions: admissions, clock: .system, configuration: configuration)
        }
        current = Mutex(makeService())
    }

    func start() async throws {
        let inbox = Inbox(localPeer: id)
        let inboxEvents = inbox.events(from: transport)
        let service = service
        let coordinator = coordinator
        tasks.withLock {
            // The app sees only the protocol.
            $0.append(Task { [self] in for await event in inboxEvents { await (self.service as any SkillService).handle(event) } })
            $0.append(Task { for await event in service.events { await coordinator.apply(event) } })
        }
        try await transport.start()
    }

    /// The app quits and launches again: a new service, restored from the
    /// coordinator's store before it handles anything.
    func restart() async {
        await service.shutdown()
        let fresh = makeService()
        let coordinator = coordinator
        tasks.withLock { $0.append(Task { for await event in fresh.events { await coordinator.apply(event) } }) }
        await fresh.restore(Array(await coordinator.interactions.values))
        current.withLock { $0 = fresh }
    }

    func stop() async {
        await service.shutdown()
        await transport.stop()
        for task in tasks.withLock({ $0 }) { task.cancel() }
    }

    func pair(with others: [Phone]) async throws {
        for other in others where other !== self {
            try await store.save(PairedPeer(publicKey: other.key, nickname: other.name, pairedAt: Timestamp(Date())))
        }
    }

    /// The link layer's hello, so each phone knows the others' cards.
    func hello(_ others: [Phone]) async throws {
        for other in others where other !== self {
            try await outbox.send(.hello(card), to: other.id, conversation: ConversationID())
        }
    }

    /// What the coordinator does when the owner sends: create the
    /// interaction, stage Compose's candidates, apply `.started`, then call
    /// `start`, applying `.failed` if it throws (ADR 0011, amendment 13).
    @discardableResult
    func organize(
        _ candidates: [PlaceCandidate], with friends: [Phone], limits: ConstraintSet = .empty,
        inputs: [Artifact] = [], chainedFrom: ConversationID? = nil, expiresIn: TimeInterval = 60
    ) async throws -> Interaction {
        let interaction = Interaction(skill: PickAPlaceSkill.ref, role: .initiator, participants: friends.map(\.id), createdAt: Timestamp(Date()))
        await coordinator.add(interaction)
        await staged.stage(candidates, for: interaction.id)
        let intent = SkillIntent(skill: PickAPlaceSkill.ref, rules: OwnerRules(constraints: limits), audience: .picked(friends.map(\.id)),
                                 expiresAt: Timestamp(Date().addingTimeInterval(expiresIn)))
        await coordinator.apply(.lifecycle(interaction.id, .started))
        do {
            try await service.start(SkillRequest(interaction: interaction.id, conversation: interaction.conversation, intent: intent,
                                                 participants: friends.map(\.id), inputs: inputs, chainedFrom: chainedFrom))
        } catch {
            await coordinator.apply(.lifecycle(interaction.id, .failed))
            throw error
        }
        return interaction
    }

    func interaction(_ conversation: ConversationID) async -> Interaction? {
        await coordinator.interaction(conversation: conversation)
    }

    func state(in conversation: ConversationID) async -> InteractionState? {
        await interaction(conversation)?.state
    }

    /// Waits for this phone's interaction in `conversation` to reach `state`.
    func reaches(_ state: InteractionState, in conversation: ConversationID, within seconds: Double = 5) async -> Bool {
        await eventually(seconds) { await self.state(in: conversation) == state }
    }

    /// The owner's tap on the current proposal card.
    func accept(in conversation: ConversationID) async throws {
        guard let interaction = await interaction(conversation), let revision = interaction.proposalRevision else {
            throw PickAPlaceError.notWaitingForYou
        }
        try await service.answer(interaction.id, with: .accept(proposal: revision))
    }

    func pass(in conversation: ConversationID) async throws {
        guard let interaction = await interaction(conversation) else { throw PickAPlaceError.notWaitingForYou }
        try await service.answer(interaction.id, with: .pass)
    }

    func attendees(in conversation: ConversationID) async -> [PeerID]? {
        guard let interaction = await interaction(conversation) else { return nil }
        let artifacts = await coordinator.produced[interaction.id] ?? []
        return artifacts.lazy.compactMap { if case .attendees(let people) = $0 { people.peers } else { nil } }.first
    }

    func agreedPlace(in conversation: ConversationID) async -> PlaceChoice? {
        guard let interaction = await interaction(conversation) else { return nil }
        let artifacts = await coordinator.produced[interaction.id] ?? []
        return artifacts.lazy.compactMap { if case .placeChoice(let place) = $0 { place } else { nil } }.first
    }
}

/// A hub, its wire log, and phones that are paired and have said hello.
struct Group {
    let hub: LoopbackHub
    let wire: Wire
    let phones: [Phone]
    private let watcher: Task<Void, Never>

    init(_ phones: [Phone], hub: LoopbackHub) async throws {
        self.hub = hub
        self.phones = phones
        let wire = Wire()
        self.wire = wire
        let deliveries = await hub.deliveries()
        watcher = Task {
            for await delivery in deliveries {
                if let envelope = try? EnvelopeCodec().decode(delivery.frame.bytes) { await wire.record(envelope) }
            }
        }
        for phone in phones { try await phone.start() }
        for phone in phones { try await phone.pair(with: phones) }
        for phone in phones { try await phone.hello(phones) }
        // Cards arrive through each Inbox loop; wait until every phone knows
        // every other phone's card, as the app would before New offers it.
        let everyone = await eventually { await phones.asyncAllSatisfy { await $0.service.cards.count == phones.count - 1 } }
        precondition(everyone, "hello did not reach every phone")
    }

    func stop() async {
        for phone in phones { await phone.stop() }
        watcher.cancel()
    }

    /// No phone's coordinator refused any event: every service reported a
    /// legal lifecycle.
    func lifecyclesWereLegal() async -> Bool {
        for phone in phones where await !phone.coordinator.rejected.isEmpty {
            Issue.record("\(phone.name) rejected \(await phone.coordinator.rejected)")
            return false
        }
        return true
    }
}

extension Array where Element: Sendable {
    func asyncAllSatisfy(_ predicate: (Element) async -> Bool) async -> Bool {
        for element in self where await !predicate(element) { return false }
        return true
    }
}
