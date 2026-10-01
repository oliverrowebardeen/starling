import Foundation
@testable import DownFor
import StarlingCore
import StarlingFakes
import StarlingTransport
import Synchronization
import Testing

/// Retries every 20 ms and gives up on an automatic step after 2 s, so a
/// loaded machine (six lanes share this Mac) does not time out healthy
/// flows. A
/// proposal waits 2 s for people.
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

/// Plays the app's lifecycle coordinator: applies every event to a real
/// `Interaction`, the way lane A's coordinator will, and records any event
/// the state machine refuses.
actor Lifecycle {
    private(set) var interactions: [InteractionID: Interaction] = [:]
    private(set) var events: [SkillEvent] = []
    private(set) var refused: [String] = []
    private(set) var artifacts: [InteractionID: [Artifact]] = [:]

    func create(_ interaction: Interaction) { interactions[interaction.id] = interaction }

    func apply(_ event: SkillEvent) {
        events.append(event)
        switch event {
        case .incoming(let id, _, _, _):
            refused.append("unexpected incoming \(id)")
        case .lifecycle(let id, let lifecycle):
            guard var interaction = interactions[id] else { return refused.append("unknown \(id)") }
            do {
                try interaction.apply(lifecycle, at: Timestamp(T.now))
                interactions[id] = interaction
            } catch {
                refused.append("\(lifecycle) in \(interaction.state): \(error)")
            }
        case .produced(let id, let artifact):
            interactions[id]?.record(artifact)
            artifacts[id, default: []].append(artifact)
        }
    }

    func interaction(_ id: InteractionID) -> Interaction? { interactions[id] }
    func state(_ id: InteractionID) -> InteractionState? { interactions[id]?.state }
    func reached(_ state: InteractionState, _ id: InteractionID) -> Bool {
        interactions[id]?.history.contains { $0.state == state } ?? false
    }
    var lifecycleEvents: [InteractionEvent] {
        events.compactMap { if case .lifecycle(_, let event) = $0 { event } else { nil } }
    }
}

/// Every envelope that crossed the hub, decoded.
actor Wire {
    private(set) var envelopes: [Envelope] = []
    func record(_ envelope: Envelope) { envelopes.append(envelope) }
    func sent(by peer: PeerID) -> [Envelope] { envelopes.filter { $0.sender == peer } }
}

/// One phone: transport, Outbox with the consent relay, Inbox loop, the
/// Down for... service, and the lifecycle it reports to.
final class Phone: Sendable {
    let name: String
    let id: PeerID
    let transport: LoopbackTransport
    let relay: DownForConsentRelay
    let service: DownForService
    let lifecycle = Lifecycle()
    let store: any DownForRequestStore
    private let tasks: Mutex<[Task<Void, Never>]> = Mutex([])

    init(
        name: String, id: PeerID, hub: LoopbackHub, model: any AgentModel, policy: any PolicyEngine, consent: any ConsentProvider,
        psi: any PSIProvider, clock: SkillClock, configuration: DownForConfiguration, store: any DownForRequestStore = InMemoryDownForRequestStore()
    ) {
        self.name = name
        self.id = id
        self.store = store
        transport = LoopbackTransport(localPeer: id, hub: hub)
        relay = DownForConsentRelay(wrapping: consent)
        let outbox = Outbox(transport: transport, policy: policy, consent: relay)
        service = DownForService(localPeer: id, outbox: outbox, model: model, psi: psi, store: store, clock: clock, timeZone: T.utc, configuration: configuration)
        relay.attach(service)
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
        extraParticipants: [PeerID] = []
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
            audience: .picked(participants), expiresAt: Timestamp(expires)
        )
        try await service.start(SkillRequest(interaction: id, conversation: conversation, intent: intent, participants: participants, inputs: inputs, chainedFrom: chainedFrom))
        return id
    }

    /// The owner taps "I'm in" on the card they are looking at.
    func imIn(_ id: InteractionID) async throws {
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
            #expect(await !phone.lifecycle.lifecycleEvents.contains(.started), "\(phone.name) reported started")
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
            conversation: message.envelope.conversation, skill: message.envelope.skill
        ))
    }
}
