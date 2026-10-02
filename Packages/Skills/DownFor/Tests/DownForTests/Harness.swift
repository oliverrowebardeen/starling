import Foundation
@testable import DownFor
import StarlingCore
import StarlingFakes
import StarlingTransport
import Synchronization
import Testing

/// Retries every 20 ms and gives up on an automatic step after 2 s, so a
/// loaded machine (six lanes share this Mac) does not time out healthy
/// flows. A proposal waits 2 s for people.
let fastConfiguration = DownForConfiguration(
    retryInterval: .milliseconds(20), maxAttempts: 100, ownerWindow: .seconds(2), maxBackoff: .milliseconds(200)
)

/// Wall time pinned to `T.now`; timers are real, except sleeps of ten
/// minutes or more (request expiry, plan end), which run `speedup` times
/// faster: by default a request that expires in 5 hours does so in 18 s.
func testClock(speedup: Int = 1_000, now: @escaping @Sendable () -> Date = { T.now }) -> SkillClock {
    SkillClock(now: now, sleep: { duration in
        try await Task.sleep(for: duration >= .seconds(600) ? duration / speedup : duration)
    })
}

/// Plays the app's lifecycle coordinator (ADR 0011, amendments 13 to 15):
/// applies every event to a real `Interaction`, records any the state
/// machine refuses, creates invitee interactions on `incoming`, applies the
/// consent events itself, and queues progress that arrives while a consent
/// sheet is up until the step resumes.
actor Lifecycle {
    private(set) var interactions: [InteractionID: Interaction] = [:]
    /// Everything the service reported, in order.
    private(set) var events: [SkillEvent] = []
    private(set) var refused: [String] = []
    /// Cards the owner passed on, hidden on this phone at once while the
    /// skill decides when the interaction ends (ADR 0011 amendment 16).
    private(set) var hidden: Set<InteractionID> = []
    private(set) var artifacts: [InteractionID: [Artifact]] = [:]
    private var queued: [InteractionID: [InteractionEvent]] = [:]
    private var consentNumbers: [InteractionID: UInt32] = [:]

    func create(_ interaction: Interaction) { interactions[interaction.id] = interaction }
    func hide(_ id: InteractionID) { hidden.insert(id) }

    func apply(_ event: SkillEvent) {
        events.append(event)
        switch event {
        case .incoming(let id, let conversation, let from, let chainedFrom):
            guard interactions[id] == nil else { return refused.append("incoming twice \(id)") }
            _ = chainedFrom
            interactions[id] = Interaction(id: id, conversation: conversation, skill: DownFor.ref, role: .invitee, participants: [from], createdAt: Timestamp(T.now))
        case .lifecycle(let id, let lifecycle):
            if case .awaitingConsent = interactions[id]?.state, Self.waitsOutASheet(lifecycle) {
                queued[id, default: []].append(lifecycle)
                return
            }
            applyNow(lifecycle, to: id)
        case .produced(let id, let artifact):
            interactions[id]?.record(artifact)
            artifacts[id, default: []].append(artifact)
        }
    }

    private static func waitsOutASheet(_ event: InteractionEvent) -> Bool {
        switch event {
        case .ownerNeeded, .proposalReady, .everyoneConfirmed: true
        default: false
        }
    }

    private func applyNow(_ event: InteractionEvent, to id: InteractionID) {
        guard var interaction = interactions[id] else { return refused.append("unknown \(id)") }
        do {
            try interaction.apply(event, at: Timestamp(T.now))
            interactions[id] = interaction
        } catch {
            refused.append("\(event) in \(interaction.state): \(error)")
        }
    }

    // The coordinator's consent events, from `Disclosure.interaction`.

    func consentAsked(_ id: InteractionID) -> UInt32? {
        guard let interaction = interactions[id], !interaction.state.isFinal else { return nil }
        let number = max(consentNumbers[id] ?? 0, interaction.consentWatermark) + 1
        consentNumbers[id] = number
        do {
            try interactions[id]!.apply(.consentNeeded(request: number), at: Timestamp(T.now))
            return number
        } catch {
            return nil
        }
    }

    func consentAnswered(_ id: InteractionID, request: UInt32, _ outcome: ConsentOutcome) {
        // A final event already closed the request (amendment 15).
        guard let interaction = interactions[id], !interaction.state.isFinal else { return }
        switch outcome {
        case .approved:
            applyNow(.consentGiven(request: request), to: id)
            if case .awaitingConsent = interactions[id]?.state { return }
            for event in queued.removeValue(forKey: id) ?? [] { applyNow(event, to: id) }
        case .declined:
            queued[id] = nil
            applyNow(.ownerPassed, to: id)
        }
    }

    func interaction(_ id: InteractionID) -> Interaction? { interactions[id] }
    func state(_ id: InteractionID) -> InteractionState? { interactions[id]?.state }
    func reached(_ state: InteractionState, _ id: InteractionID) -> Bool {
        interactions[id]?.history.contains { $0.state == state } ?? false
    }
    /// The lifecycle events the service reported.
    var lifecycleEvents: [InteractionEvent] {
        events.compactMap { if case .lifecycle(_, let event) = $0 { event } else { nil } }
    }
    /// Invitee interactions the service created.
    var invitations: [InteractionID] {
        events.compactMap { if case .incoming(let id, _, _, _) = $0 { id } else { nil } }
    }
}

/// The app's consent provider as the coordinator runs it: asks the owner
/// (here a scripted or gated provider) and applies the consent events to
/// the interaction the disclosure names.
struct CoordinatorConsent: ConsentProvider {
    let owner: any ConsentProvider
    let lifecycle: Lifecycle

    func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        let request = await disclosure.interaction.asyncMap { await lifecycle.consentAsked($0) } ?? nil
        let outcome = await owner.requestConsent(for: disclosure)
        if let id = disclosure.interaction, let request { await lifecycle.consentAnswered(id, request: request, outcome) }
        return outcome
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}

/// Every envelope that crossed the hub, decoded.
actor Wire {
    private(set) var envelopes: [Envelope] = []
    func record(_ envelope: Envelope) { envelopes.append(envelope) }
    func sent(by peer: PeerID) -> [Envelope] { envelopes.filter { $0.sender == peer } }
}

/// One phone: transport, Outbox with the coordinator's consent provider,
/// Inbox loop, the Down for... service, and the lifecycle it reports to.
final class Phone: Sendable {
    let name: String
    let id: PeerID
    let transport: LoopbackTransport
    let service: DownForService
    let lifecycle = Lifecycle()
    let store: any DownForRequestStore
    /// The phone's ledger, shared by its Outbox and service, and kept
    /// across a simulated restart like the app's persisted one.
    let ledger: InMemoryConversationLedger
    private let tasks: Mutex<[Task<Void, Never>]> = Mutex([])

    init(
        name: String, id: PeerID, hub: LoopbackHub, model: any AgentModel, policy: any PolicyEngine, consent: any ConsentProvider,
        psi: any PSIProvider, clock: SkillClock, configuration: DownForConfiguration, store: any DownForRequestStore = InMemoryDownForRequestStore(),
        pairedPeers: (any PairedPeerStore)? = nil, ledger: InMemoryConversationLedger = InMemoryConversationLedger()
    ) {
        self.name = name
        self.id = id
        self.store = store
        self.ledger = ledger
        transport = LoopbackTransport(localPeer: id, hub: hub)
        let outbox = Outbox(transport: transport, policy: policy, consent: CoordinatorConsent(owner: consent, lifecycle: lifecycle), ledger: ledger)
        service = DownForService(
            localPeer: id, outbox: outbox, model: model, psi: psi, ledger: ledger, store: store, pairedPeers: pairedPeers,
            clock: clock, timeZone: T.utc, configuration: configuration
        )
    }

    func start() async throws {
        let inbox = Inbox(localPeer: id)
        let events = inbox.events(from: transport)
        let service: any SkillService = service
        let lifecycle = lifecycle
        tasks.withLock {
            $0.append(Task { for await event in events { await service.handle(event) } })
            $0.append(Task { for await event in service.events { await lifecycle.apply(event) } })
        }
        try await transport.start()
    }

    /// An abrupt kill, as iOS does to apps routinely: the transport and the
    /// loops stop, and the service is never shut down.
    func crash() async {
        await transport.stop()
        for task in tasks.withLock({ $0 }) { task.cancel() }
    }

    func stop() async {
        await service.shutdown()
        await transport.stop()
        for task in tasks.withLock({ $0 }) { task.cancel() }
    }

    /// Composes "Down for <activity>" for `friends`, as New would after the
    /// owner reviewed the chips.
    @discardableResult
    func down(
        for activities: [String], time: [TimeSlot]? = [T.slot(19, 23)], with friends: [Phone], avoided: [String] = [],
        budget: Int64? = nil, expires: Date = T.at(24), chainedFrom: ConversationID? = nil, inputs: [Artifact] = [],
        extraParticipants: [PeerID] = [], mode: SendMode = .askQuietly
    ) async throws -> InteractionID {
        let id = InteractionID()
        let conversation = ConversationID()
        let participants = friends.map(\.id) + extraParticipants
        // The coordinator applies `.started` when the owner sends, then
        // calls `start` (ADR 0011, amendment 13).
        var interaction = Interaction(id: id, conversation: conversation, skill: DownFor.ref, role: .initiator, participants: participants, createdAt: Timestamp(T.now))
        try interaction.apply(.started, at: Timestamp(T.now))
        await lifecycle.create(interaction)
        let intent = SkillIntent(
            skill: DownFor.ref, rules: try T.rules(time: time, liked: activities, avoided: avoided, maxBudget: budget),
            audience: .picked(participants), mode: mode, expiresAt: Timestamp(expires)
        )
        try await service.start(SkillRequest(interaction: id, conversation: conversation, intent: intent, participants: participants, inputs: inputs, chainedFrom: chainedFrom))
        return id
    }

    /// Ask quietly for several friends, as lane A's coordinator does: one
    /// initiator interaction per friend, each with its own conversation
    /// (ADR 0011 amendment 17). In `friends` order.
    func downEach(
        for activities: [String], time: [TimeSlot]? = [T.slot(19, 23)], with friends: [Phone], expires: Date = T.at(24)
    ) async throws -> [InteractionID] {
        var ids: [InteractionID] = []
        for friend in friends { ids.append(try await down(for: activities, time: time, with: [friend], expires: expires)) }
        return ids
    }

    /// The owner taps pass on a card, as lane A's coordinator handles it
    /// (ADR 0011 amendment 16): the card hides at once and the skill is
    /// told; the interaction ends when the skill reports it.
    func pass(_ id: InteractionID) async throws {
        await lifecycle.hide(id)
        try await service.answer(id, with: .pass)
    }

    /// The owner taps "I'm in" on the card they are looking at. A consent
    /// sheet covers the card while it is up, as in the app.
    func imIn(_ id: InteractionID) async throws {
        try await eventually("\(name) sees the card") { await self.lifecycle.state(id) == .proposed }
        let revision = try #require(await lifecycle.interaction(id)?.proposalRevision)
        try await service.answer(id, with: .accept(proposal: revision))
    }

    func waitFor(_ state: InteractionState, _ id: InteractionID, timeout: Duration = .seconds(15)) async throws {
        try await eventually(timeout: timeout, "\(name) \(state)") {
            // A plan arrives as its own event right after `planned`.
            let reached = await self.lifecycle.reached(state, id)
            let plan = await self.lifecycle.interaction(id)?.plan
            return reached && (state != .planned || plan != nil)
        }
    }

    func waitForProposal(_ id: InteractionID, revision: UInt32 = 1, timeout: Duration = .seconds(15)) async throws {
        try await eventually(timeout: timeout, "\(name) proposal \(revision)") {
            let interaction = await self.lifecycle.interaction(id)
            return interaction?.proposalRevision == revision && interaction?.state == .proposed
        }
    }
}

/// Phones on one Loopback hub, named A, B, C... in `PeerID` order, so tests
/// know which request starts the group (the lowest).
final class World: Sendable {
    let hub = LoopbackHub()
    let wire = Wire()
    let phones: [Phone]
    private let observer: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(
        _ count: Int,
        model: any AgentModel = ScriptedAgentModel(),
        policy: any PolicyEngine = FixedPolicyEngine(.allow),
        consent: any ConsentProvider = ScriptedConsentProvider(.approved),
        psi: any PSIProvider = InsecurePSIStub(),
        clock: SkillClock = testClock(),
        configuration: DownForConfiguration = fastConfiguration,
        stores: [any DownForRequestStore]? = nil
    ) {
        let ids = (0..<count).map { _ in PeerID.random() }.sorted()
        let hub = hub
        phones = ids.enumerated().map { index, id in
            Phone(
                name: String(UnicodeScalar(UInt8(65 + index))), id: id, hub: hub, model: model, policy: policy, consent: consent,
                psi: psi, clock: clock, configuration: configuration, store: stores?[index] ?? InMemoryDownForRequestStore()
            )
        }
    }

    subscript(name: String) -> Phone { phones.first { $0.name == name }! }

    func start() async throws {
        let deliveries = await hub.deliveries()
        let wire = wire
        observer.withLock {
            $0 = Task {
                for await delivery in deliveries {
                    if let envelope = try? EnvelopeCodec().decode(delivery.frame.bytes) { await wire.record(envelope) }
                }
            }
        }
        for phone in phones { try await phone.start() }
    }

    func stop() async {
        for phone in phones { await phone.stop() }
        observer.withLock { $0?.cancel() }
    }

    /// No phone's lifecycle refused an event, and no service reported
    /// `.started`, which only the coordinator applies (ADR 0011, amendment 13).
    func expectCleanLifecycles() async {
        for phone in phones {
            let refused = await phone.lifecycle.refused
            #expect(refused.isEmpty, "\(phone.name) refused: \(refused)")
            let reported = await phone.lifecycle.lifecycleEvents
            #expect(!reported.contains(.started), "\(phone.name) reported started")
            // Consent and plan ends are the coordinator's (amendment 15).
            #expect(!reported.contains { event in
                switch event {
                case .consentNeeded, .consentGiven, .consentCancelled, .planEnded: true
                default: false
                }
            }, "\(phone.name) reported a coordinator's event")
        }
    }
}

func eventually(timeout: Duration = .seconds(15), _ what: String, _ condition: @Sendable () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for \(what)")
}

/// A consent sheet the test answers when it chooses. Counts the sheets.
actor GatedConsent: ConsentProvider {
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

/// Asks for consent on every message, with a disclosure that names the
/// conversation and skill, as lane G's policy does.
func consentForEverything() -> FixedPolicyEngine {
    FixedPolicyEngine { message in
        .needsConsent(Disclosure(
            recipient: message.envelope.recipient, recipientModel: nil, items: [],
            conversation: message.envelope.conversation, skill: message.envelope.skill, interaction: message.context.interaction
        ))
    }
}

/// Virtual time for the service's clock: a sleep returns only when the
/// test advances past its deadline, so no deadline depends on how busy the
/// machine is. Wall time stays pinned to the date given to `clock(now:)`.
actor VirtualTime {
    private(set) var now: Duration = .zero
    private var sleepers: [UUID: (at: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]

    /// When each pending sleep is due, earliest first.
    var due: [Duration] { sleepers.values.map(\.at).sorted() }

    nonisolated func clock(now date: Date) -> SkillClock {
        SkillClock(now: { date }, sleep: { try await self.sleep($0) })
    }

    func sleep(_ duration: Duration) async throws {
        guard duration > .zero else { return }
        let id = UUID()
        let at = now + duration
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = (at, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    /// Moves time forward to `time`, waking every sleep due by then.
    func advance(to time: Duration) {
        now = max(now, time)
        for (id, sleeper) in sleepers.sorted(by: { $0.value.at < $1.value.at }) where sleeper.at <= now {
            sleepers[id] = nil
            sleeper.continuation.resume()
        }
    }
}
