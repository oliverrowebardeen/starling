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
    /// Progress held while a consent sheet is up (ADR 0011, amendment 15).
    private var queued: [InteractionID: [InteractionEvent]] = [:]
    private var nextConsent: UInt32 = 0

    func add(_ interaction: Interaction) { interactions[interaction.id] = interaction }

    func apply(_ event: SkillEvent) {
        received.append(event)
        switch event {
        case .incoming(let id, let conversation, let from, let chainedFrom):
            incoming.append((id, from, chainedFrom))
            var interaction = Interaction(id: id, conversation: conversation, skill: PickAPlaceSkill.ref, role: .invitee,
                                          participants: [from], createdAt: Timestamp(Date()))
            // As the app does: the request's chain hint, for grouping and
            // for a restart.
            try? interaction.setFriendChainHint(chainedFrom)
            interactions[id] = interaction
        case .lifecycle(let id, let lifecycle):
            guard let interaction = interactions[id] else { rejected.append((event, "unknown interaction")); return }
            // While the sheet is up, progress waits its turn; anything else,
            // an end included, applies at once.
            if case .awaitingConsent = interaction.state, Self.waitsForConsent(lifecycle) {
                queued[id, default: []].append(lifecycle)
                return
            }
            applyNow(lifecycle, to: id, reporting: event)
        case .produced(let id, let artifact):
            produced[id, default: []].append(artifact)
            interactions[id]?.record(artifact)
        }
    }

    static func waitsForConsent(_ event: InteractionEvent) -> Bool {
        switch event {
        case .ownerNeeded, .proposalReady, .everyoneConfirmed: true
        default: false
        }
    }

    private func applyNow(_ lifecycle: InteractionEvent, to id: InteractionID, reporting event: SkillEvent? = nil) {
        guard var interaction = interactions[id] else { return }
        do {
            try interaction.apply(lifecycle, at: Timestamp(Date()))
            interactions[id] = interaction
        } catch {
            rejected.append((event ?? .lifecycle(id, lifecycle), "\(error)"))
        }
        if interaction.state.isFinal { queued[id] = nil }
        drain(id)
    }

    /// Applies held progress, in order, once the step has resumed.
    private func drain(_ id: InteractionID) {
        while let interaction = interactions[id], !interaction.state.isFinal, !Self.isSuspended(interaction.state),
              let next = queued[id]?.first {
            queued[id]?.removeFirst()
            applyNow(next, to: id)
        }
    }

    private static func isSuspended(_ state: InteractionState) -> Bool {
        if case .awaitingConsent = state { true } else { false }
    }

    func interaction(conversation: ConversationID) -> Interaction? {
        interactions.values.first { $0.conversation == conversation }
    }

    func state(_ id: InteractionID) -> InteractionState? { interactions[id]?.state }

    /// The interaction a sheet is for: by the ID the service put in the
    /// send's context (Core v2.1), else by conversation.
    func target(_ disclosure: Disclosure) -> Interaction? {
        if let id = disclosure.interaction, let found = interactions[id] { return found }
        return disclosure.conversation.flatMap { interaction(conversation: $0) }
    }

    func consentRequested(for disclosure: Disclosure) -> UInt32? {
        guard var interaction = target(disclosure) else { return nil }
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
    func consentDeclined(for disclosure: Disclosure) {
        guard var interaction = target(disclosure) else { return }
        try? interaction.apply(.ownerPassed, at: Timestamp(Date()))
        interactions[interaction.id] = interaction
    }

    func consentApproved(_ request: UInt32, for disclosure: Disclosure) {
        settle(.consentGiven(request: request), for: disclosure)
    }

    /// The send was cancelled while its sheet was up: nobody answered and
    /// nothing was sent (ADR 0011, amendment 15).
    func consentCancelled(_ request: UInt32, for disclosure: Disclosure) {
        settle(.consentCancelled(request: request), for: disclosure)
    }

    private func settle(_ event: InteractionEvent, for disclosure: Disclosure) {
        // A sheet for an interaction that has already ended is dismissed,
        // as the app's sheet is: a withdrawal can end it before the sheet
        // it cancelled reports back.
        guard var interaction = target(disclosure), !interaction.state.isFinal else { return }
        do {
            try interaction.apply(event, at: Timestamp(Date()))
            interactions[interaction.id] = interaction
        } catch {
            rejected.append((.lifecycle(interaction.id, event), "\(error)"))
        }
        drain(interaction.id)
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
        _ = await eventually(1) { await coordinator.target(disclosure) != nil }
        let request = await coordinator.consentRequested(for: disclosure)
        await gate?.wait()
        // The service cancelled the send while the sheet was up.
        if Task.isCancelled {
            if let request { await coordinator.consentCancelled(request, for: disclosure) }
            return .declined
        }
        if outcome == .approved, let request { await coordinator.consentApproved(request, for: disclosure) }
        if outcome == .declined { await coordinator.consentDeclined(for: disclosure) }
        return outcome
    }
}

/// Holds consent sheets open until the test opens it.
actor ConsentGate {
    private var isOpen = false
    private(set) var waiting = 0

    /// Returns when the gate opens, or as soon as the waiting task is
    /// cancelled, as a real sheet is dismissed.
    func wait() async {
        guard !isOpen else { return }
        waiting += 1
        while !isOpen, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func open() { isOpen = true }
}

/// One phone: transport, Outbox, Inbox loop, the service, and a coordinator.
final class Phone: Sendable {
    let name: String
    let key: IdentityPublicKey
    let transport: LossyTransport
    let store = InMemoryPairedPeerStore()
    let staged = StagedCandidates()
    /// Shared by every service this phone runs, as the app's log would be.
    let ledger = InMemoryPickAPlaceLedger()
    /// The phone's conversation ledger (ADR 0021), enforced by its Outbox
    /// and kept across restarts, as the app keeps it.
    let conversations = InMemoryConversationLedger()
    let coordinator = Coordinator()
    let consent: CoordinatorConsent
    /// Every send the Outbox made, with its context.
    let sends = RecordingOutboxObserver()
    /// Holds the service's events on their way to the coordinator, as a
    /// busy event loop can, while a consent sheet goes straight to it.
    let events = EventHold()
    /// This phone's own plans, by plan conversation, as the app's store
    /// holds them.
    let plans = PlanBook()
    /// The app's holds (ADR 0023). In memory, so a restart gets new ones.
    private let currentHolds = Mutex(PlanChangeHolds())
    var holds: PlanChangeHolds { currentHolds.withLock { $0 } }
    /// Wraps `sends`; holds nothing unless a test asks (issue #105).
    let hold: DidSendHold
    let outbox: Outbox
    let card: AgentCard
    private let current: Mutex<PickAPlaceService>
    private let makeService: @Sendable (PlanChangeHolds) -> PickAPlaceService
    private let tasks = Mutex<[Task<Void, Never>]>([])
    /// Each terminal event the service reported, and whether its
    /// conversation was already retired when it did (ADR 0021).
    let endings = Mutex<[(event: InteractionEvent, retired: Bool, withdrawalRecorded: Bool)]>([])

    /// The service now running; `restart()` replaces it.
    var service: PickAPlaceService { current.withLock { $0 } }

    var id: PeerID { key.peerID }

    init(
        _ name: String, hub: LoopbackHub, maps: FakeMaps, limits: ConstraintSet = .empty,
        ownerLimits: (@Sendable () async -> ConstraintSet)? = nil, placeLedger: (any PickAPlaceLedger)? = nil,
        policy: any PolicyEngine = FixedPolicyEngine(.allow), consent outcome: ConsentOutcome = .approved, gate: ConsentGate? = nil,
        skills: [SkillRef] = [PickAPlaceSkill.ref], model: ModelLocality = .onDevice, configuration: PickAPlaceConfiguration = fastConfiguration,
        wrapHolds: (@Sendable (PlanChangeHolds) -> any PlanChangeHolding)? = nil
    ) {
        self.name = name
        key = try! IdentityPublicKey(bytes: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        transport = LossyTransport(LoopbackTransport(localPeer: key.peerID, hub: hub))
        consent = CoordinatorConsent(coordinator: coordinator, outcome: outcome, gate: gate)
        hold = DidSendHold(sends)
        outbox = Outbox(transport: transport, policy: policy, consent: consent, observer: hold, ledger: conversations)
        card = try! AgentCard(model: model, capabilities: [], skills: skills)
        let (peer, outbox, store, staged, conversations) = (key.peerID, outbox, store, staged, conversations)
        let ledger: any PickAPlaceLedger = placeLedger ?? self.ledger
        let readLimits: @Sendable () async -> ConstraintSet = ownerLimits ?? { limits }
        let book = plans
        makeService = { holds in
            PickAPlaceService(localPeer: peer, outbox: outbox, pairedPeers: store, candidates: staged, maps: maps,
                              ownerLimits: readLimits, ledger: ledger, conversations: conversations,
                              plans: { await book.plan(for: $0) }, holds: wrapHolds?(holds) ?? holds, clock: .system,
                              configuration: configuration)
        }
        current = Mutex(makeService(currentHolds.withLock { $0 }))
    }

    func start() async throws {
        let inbox = Inbox(localPeer: id)
        let inboxEvents = inbox.events(from: transport)
        let service = service
        tasks.withLock {
            // The app sees only the protocol.
            $0.append(Task { [self] in for await event in inboxEvents { await (self.service as any SkillService).handle(event) } })
            $0.append(Task { [self] in for await event in service.events { await self.deliver(event) } })
        }
        try await transport.start()
    }

    /// The app quits and launches again: a new service, restored from the
    /// coordinator's store before it handles anything.
    /// A relaunch: a new service with new, empty holds, which `beforeRestore`
    /// can fill as another skill restoring first would.
    func restart(beforeRestore: (@Sendable (PlanChangeHolds) async -> Void)? = nil) async {
        await service.shutdown()
        let holds = PlanChangeHolds()
        await beforeRestore?(holds)
        currentHolds.withLock { $0 = holds }
        let fresh = makeService(holds)
        let coordinator = coordinator
        tasks.withLock { $0.append(Task { [self] in for await event in fresh.events { await self.deliver(event) } }) }
        await fresh.restore(Array(await coordinator.interactions.values))
        current.withLock { $0 = fresh }
    }

    static func isTerminal(_ event: InteractionEvent) -> Bool {
        switch event {
        case .ownerPassed, .withdrawn, .noAgreement, .expired, .failed, .unsupported, .blockedByPrivacy: true
        default: false
        }
    }

    /// Hands an event to the coordinator, noting first whether a terminal
    /// one arrived only after its conversation was retired.
    func deliver(_ event: SkillEvent) async {
        await events.pass(event)
        if case .lifecycle(let id, let lifecycle) = event, Self.isTerminal(lifecycle),
           let conversation = await coordinator.interactions[id]?.conversation {
            let retired = (try? await conversations.isRetired(conversation)) ?? false
            let recorded = ((try? await ledger.pendingWithdrawals()) ?? []).contains { $0.conversation == conversation }
            endings.withLock { $0.append((lifecycle, retired, recorded)) }
        }
        await coordinator.apply(event)
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
        // A request chained from a plan is a link of it, as the planner
        // makes one.
        let chain = chainedFrom.map {
            ChainLink(parent: InteractionID(), parentConversation: $0, consumed: [.plan], trigger: .atConfirm, optedInAt: Timestamp(Date()))
        }
        let interaction = Interaction(skill: PickAPlaceSkill.ref, role: .initiator, participants: friends.map(\.id), createdAt: Timestamp(Date()),
                                      chain: chain)
        await coordinator.add(interaction)
        await staged.stage(candidates, for: interaction.id)
        let intent = SkillIntent(skill: PickAPlaceSkill.ref, rules: OwnerRules(constraints: limits), audience: .picked(friends.map(\.id)),
                                 mode: .invite, expiresAt: Timestamp(Date().addingTimeInterval(expiresIn)))
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
        // The latest: a roster can shrink after the plan is confirmed.
        return artifacts.compactMap { if case .attendees(let people) = $0 { people.peers } else { nil } }.last
    }

    func agreedPlace(in conversation: ConversationID) async -> PlaceChoice? {
        guard let interaction = await interaction(conversation) else { return nil }
        let artifacts = await coordinator.produced[interaction.id] ?? []
        return artifacts.lazy.compactMap { if case .placeChoice(let place) = $0 { place } else { nil } }.first
    }
}

/// Holds a phone's service events, in order, from the first one that
/// matches until the test releases them.
actor EventHold {
    private var matches: (@Sendable (SkillEvent) -> Bool)?
    private var isHolding = false
    private(set) var held = 0

    func hold(from matching: @escaping @Sendable (SkillEvent) -> Bool) { matches = matching }

    func release() {
        matches = nil
        isHolding = false
    }

    func pass(_ event: SkillEvent) async {
        if let matches, matches(event) { isHolding = true }
        guard isHolding else { return }
        held += 1
        while isHolding { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Holds that wait for the test before granting a hold, so a test can end
/// a card while its yes waits on one.
actor GatedHolds: PlanChangeHolding {
    let base: PlanChangeHolds
    private var isOpen = false
    private(set) var waiting = 0

    init(_ base: PlanChangeHolds) { self.base = base }

    func open() { isOpen = true }

    func hold(_ plan: ConversationID, for change: ConversationID) async -> Bool {
        waiting += 1
        while !isOpen { try? await Task.sleep(for: .milliseconds(5)) }
        return await base.hold(plan, for: change)
    }

    func release(_ plan: ConversationID, for change: ConversationID) async { await base.release(plan, for: change) }
    func holder(of plan: ConversationID) async -> ConversationID? { await base.holder(of: plan) }
}

/// A phone's own plans, by the conversation that agreed them (`Plan.origin`).
actor PlanBook {
    private var plans: [ConversationID: Plan] = [:]

    func hold(_ plan: Plan) { plans[plan.origin] = plan }
    func plan(for conversation: ConversationID) -> Plan? { plans[conversation] }
}

/// Holds Outbox's `didSend` for chosen kinds of message, as an audit
/// journal that is slow to write can (issue #105): the transport has
/// delivered the envelope, but the sender's `send` has not returned.
actor DidSendHold: OutboxObserver {
    private let inner: RecordingOutboxObserver
    private var kinds: Set<MessageBody.Kind> = []
    private var waiters: [MessageID: CheckedContinuation<Void, Never>] = [:]
    /// Envelopes held so far, in order.
    private(set) var held: [Envelope] = []

    init(_ inner: RecordingOutboxObserver) { self.inner = inner }

    func hold(_ kinds: Set<MessageBody.Kind>) { self.kinds = kinds }

    /// Lets every held send return. With `holdingOn`, later sends of the
    /// same kinds are still held, so a retry cannot stand in for the send
    /// that was held.
    func release(holdingOn: Bool = false) {
        if !holdingOn { kinds = [] }
        let pending = waiters.values
        waiters = [:]
        for waiter in pending { waiter.resume() }
    }

    /// Lets one held send return; the others stay held.
    func release(_ id: MessageID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    /// Whether the send of `id` is held now.
    func isHolding(_ id: MessageID) -> Bool { waiters[id] != nil }

    func outbox(willSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async throws {
        try await inner.outbox(willSend: envelope, context: context, decision: decision, disclosed: disclosed)
    }

    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {
        await outbox(didSend: envelope, context: context, decision: decision, disclosed: nil)
    }

    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async {
        await inner.outbox(didSend: envelope, context: context, decision: decision, disclosed: disclosed)
        guard kinds.contains(envelope.body.kind) else { return }
        held.append(envelope)
        await withCheckedContinuation { waiters[envelope.id] = $0 }
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
