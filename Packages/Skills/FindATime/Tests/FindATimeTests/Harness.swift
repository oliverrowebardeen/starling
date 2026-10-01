@testable import FindATime
import Foundation
import StarlingAvailability
import StarlingAvailabilityFakes
import StarlingCore
import StarlingFakes
import StarlingTransport
import Synchronization
import Testing

/// Wall time the test moves by hand; timers are real and short.
final class TestClock: Sendable {
    private let current: Mutex<Date>
    init(_ start: Date = T.at(8)) { current = Mutex(start) }
    var now: Date { current.withLock { $0 } }
    func advance(hours: Double) { current.withLock { $0 = $0.addingTimeInterval(hours * 3600) } }
    var clock: FindATimeClock {
        FindATimeClock(now: { self.now }, sleep: { try await Task.sleep(for: $0) })
    }
}

/// Retries every 20 ms; deadlines are far away unless a test moves the clock.
let fastConfiguration = FindATimeConfiguration(retryInterval: .milliseconds(20), maxAttempts: 50)

/// Marker strings planted in calendar events. None may appear anywhere a
/// peer or a prompt can see.
enum Canary {
    static let all = ["Oncology follow-up", "4 Secret Street", "Dr. Hidden", "divorce lawyer", "Sam Private"]

    static func events(day: Double = 0) -> [FakeCalendarEvent] {
        [
            FakeCalendarEvent(title: all[0], location: all[1], notes: all[3], attendees: [all[2]], start: T.at(day * 24 + 9), end: T.at(day * 24 + 12)),
            FakeCalendarEvent(title: all[4], start: T.at(day * 24 + 13), end: T.at(day * 24 + 14)),
        ]
    }

    static func leaks(in text: String) -> [String] { all.filter { text.localizedCaseInsensitiveContains($0) } }
}

/// The app's lifecycle coordinator, reduced to what tests need: it applies
/// every event to an `InteractionStore` and keeps what it could not apply.
actor Coordinator {
    let store = InMemoryInteractionStore()
    private(set) var log: [SkillEvent] = []
    private(set) var rejected: [SkillEvent] = []
    private(set) var produced: [InteractionID: [Artifact]] = [:]

    func consume(_ event: SkillEvent) async {
        log.append(event)
        do {
            switch event {
            case .incoming(let id, let conversation, let from, _):
                try await store.save(Interaction(
                    id: id, conversation: conversation, skill: FindATimeSkill.ref, role: .invitee,
                    participants: [from], createdAt: Timestamp(Date())
                ))
            case .lifecycle(let id, let lifecycle):
                guard var interaction = try await store.interaction(id) else { rejected.append(event); return }
                try interaction.apply(lifecycle, at: Timestamp(Date()))
                try await store.save(interaction)
            case .produced(let id, let artifact):
                produced[id, default: []].append(artifact)
                guard var interaction = try await store.interaction(id) else { return }
                interaction.record(artifact)
                try await store.save(interaction)
            }
        } catch {
            rejected.append(event)
        }
    }

    func begin(_ interaction: Interaction) async throws { try await store.save(interaction) }

    /// What the app's consent provider does around a sheet (the contract in
    /// docs/requests/P15-C.md): it applies `consentNeeded` before asking and
    /// `consentGiven` after an approval. On a decline it applies nothing;
    /// the skill reports what declining means.
    func applyConsent(_ event: (UInt32) -> InteractionEvent, conversation: ConversationID?, opening: Bool) async -> UInt32? {
        guard let conversation else { return nil }
        for _ in 0..<200 {
            if var interaction = try? await store.interaction(conversation: conversation) {
                let request = opening ? interaction.consentWatermark + 1 : (interaction.pendingConsents.max() ?? 0)
                if (try? interaction.apply(event(request), at: Timestamp(Date()))) != nil {
                    try? await store.save(interaction)
                    consents.append(event(request))
                    return request
                }
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        rejected.append(.lifecycle(InteractionID(), event(0)))
        return nil
    }

    private(set) var consents: [InteractionEvent] = []

    func all() async -> [Interaction] { (try? await store.all()) ?? [] }
    func interaction(_ id: InteractionID) async -> Interaction? { try? await store.interaction(id) }
    func invitee() async -> Interaction? { await all().first { $0.role == .invitee } }
    func initiator() async -> Interaction? { await all().first { $0.role == .initiator } }
}

/// A `Transport` that silently loses chosen outbound envelopes, as a flaky
/// link would after `send` returned.
actor LossyTransport: Transport {
    nonisolated let base: LoopbackTransport
    nonisolated var kind: TransportKind { base.kind }
    nonisolated var localPeer: PeerID { base.localPeer }
    nonisolated var events: AsyncStream<TransportEvent> { base.events }
    private var rules: [(remaining: Int, matches: @Sendable (Envelope) -> Bool)] = []
    private(set) var lost: [Envelope] = []

    init(_ base: LoopbackTransport) { self.base = base }

    func lose(_ count: Int = 1, where matches: @escaping @Sendable (Envelope) -> Bool) { rules.append((count, matches)) }

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

/// The app's consent provider around a scripted owner.
struct LifecycleConsent: ConsentProvider {
    let owner: any ConsentProvider
    let coordinator: Coordinator

    func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        _ = await coordinator.applyConsent({ .consentNeeded(request: $0) }, conversation: disclosure.conversation, opening: true)
        let outcome = await owner.requestConsent(for: disclosure)
        if outcome == .approved {
            _ = await coordinator.applyConsent({ .consentGiven(request: $0) }, conversation: disclosure.conversation, opening: false)
        }
        return outcome
    }
}

/// One phone: transport, Outbox, Inbox loop, calendar, service, coordinator.
final class Phone: Sendable {
    let name: String
    let key: IdentityPublicKey
    let transport: LossyTransport
    let peers = InMemoryPairedPeerStore()
    let calendar: FakeCalendarStore
    let use: Mutex<CalendarUse>
    let policy: any PolicyEngine
    let consent: any ConsentProvider
    let checkpoints = InMemoryFindATimeCheckpoints()
    let clock: TestClock
    private let state: Mutex<(service: FindATimeService?, outbox: Outbox?, coordinator: Coordinator, tasks: [Task<Void, Never>])>
    private let inboxLoop: Mutex<Task<Void, Never>?> = Mutex(nil)

    var id: PeerID { key.peerID }
    var service: FindATimeService { state.withLock { $0.service! } }
    var coordinator: Coordinator { state.withLock { $0.coordinator } }

    init(name: String, hub: LoopbackHub, calendar: FakeCalendarStore, use: CalendarUse = .useMyCalendar,
         policy: any PolicyEngine = FixedPolicyEngine(.allow), consent: any ConsentProvider = ScriptedConsentProvider(.approved), clock: TestClock) {
        self.name = name
        key = try! IdentityPublicKey(bytes: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        transport = LossyTransport(LoopbackTransport(localPeer: key.peerID, hub: hub))
        self.calendar = calendar
        self.use = Mutex(use)
        self.policy = policy
        self.consent = consent
        self.clock = clock
        state = Mutex((nil, nil, Coordinator(), []))
    }

    /// Builds a service and its coordinator loop. Called at start and again
    /// to simulate an app restart.
    func makeService(configuration: FindATimeConfiguration = fastConfiguration) {
        let outbox = Outbox(transport: transport, policy: policy, consent: LifecycleConsent(owner: consent, coordinator: coordinator))
        let availability = OwnerAvailability.standard(calendar: calendar, use: { self.use.withLock { $0 } })
        let service = FindATimeService(
            localPeer: id, outbox: outbox, pairedPeers: peers, availability: availability, checkpoints: checkpoints,
            clock: clock.clock, timeZone: T.utc, configuration: configuration
        )
        state.withLock { state in
            let coordinator = state.coordinator
            state.tasks.append(Task { for await event in service.events { await coordinator.consume(event) } })
            state.service = service
            state.outbox = outbox
        }
    }

    /// Sends a crafted message through this phone's Outbox, as a friend's
    /// modified app could.
    @discardableResult
    func send(_ body: MessageBody, to peer: Phone, conversation: ConversationID, skill: SkillRef? = FindATimeSkill.ref, chainedFrom: ConversationID? = nil) async throws -> Envelope {
        let outbox = state.withLock { $0.outbox! }
        return try await outbox.send(body, to: peer.id, conversation: conversation, skill: skill, chainedFrom: chainedFrom)
    }

    static let card = try! AgentCard(model: .onDevice, capabilities: [], skills: [FindATimeSkill.ref])

    /// The link-level hello the app sends when a friend's link comes up, so
    /// the policy knows where the friend's model runs.
    func greet(_ others: [Phone]) async throws {
        let outbox = state.withLock { $0.outbox! }
        for other in others where other !== self {
            try await outbox.send(.hello(Self.card), to: other.id, conversation: ConversationID())
        }
    }

    func start() async throws {
        makeService()
        let inbox = Inbox(localPeer: id)
        let events = inbox.events(from: transport)
        inboxLoop.withLock {
            $0 = Task { [weak self] in
                for await event in events { await self?.service.handle(event) }
            }
        }
        try await transport.start()
    }

    /// Simulates quitting and relaunching the app: the old service stops,
    /// a new one restores from the coordinator's store and the checkpoints.
    func restart(configuration: FindATimeConfiguration = fastConfiguration) async {
        let old = service
        await old.flushCheckpoints()
        await old.shutdown()
        makeService(configuration: configuration)
        await service.restore(await coordinator.all())
    }

    func greetAgain(_ world: World) async throws {
        for other in world.phones.withLock({ $0 }) where other !== self { try await other.greet([self]) }
    }

    func stop() async {
        await service.shutdown()
        await transport.stop()
        inboxLoop.withLock { $0?.cancel() }
        for task in state.withLock({ $0.tasks }) { task.cancel() }
    }

    func pair(with other: Phone) async throws {
        try await peers.save(PairedPeer(publicKey: other.key, nickname: other.name, pairedAt: Timestamp(T.monday)))
    }

    /// Starts Find a time as the app would: record the draft, then start.
    @discardableResult
    func findATime(
        with friends: [Phone], range: [TimeSlot] = [T.slot(8, 24)], daily: (Int, Int)? = nil,
        activity: String? = "stats", expiresIn hours: Double = 48, chainedFrom: ConversationID? = nil
    ) async throws -> InteractionID {
        var constraints: [IssueKey: [Constraint]] = [.time: [try Constraint(.within(range))]]
        if let daily { constraints[.time]!.append(try Constraint(.dailyWindow(from: daily.0, to: daily.1))) }
        if let activity { constraints[.activity] = [try Constraint(.prefers(liked: [Keyword(activity)], avoided: []), strength: .soft)] }
        let intent = SkillIntent(
            skill: FindATimeSkill.ref, rules: OwnerRules(constraints: try ConstraintSet(constraints)),
            audience: .picked(friends.map(\.id)), expiresAt: Timestamp(clock.now.addingTimeInterval(hours * 3600))
        )
        let interaction = Interaction(skill: FindATimeSkill.ref, role: .initiator, participants: friends.map(\.id), createdAt: Timestamp(Date()))
        try await coordinator.begin(interaction)
        try await service.start(SkillRequest(
            interaction: interaction.id, conversation: interaction.conversation, intent: intent,
            participants: friends.map(\.id), chainedFrom: chainedFrom
        ))
        return interaction.id
    }

    // MARK: Owner actions through the shared screens

    func pendingQuestion(_ id: InteractionID? = nil) async -> (InteractionID, SkillQuestion)? {
        for interaction in await coordinator.all() where id == nil || interaction.id == id {
            if let question = interaction.pendingQuestion { return (interaction.id, question) }
        }
        return nil
    }

    func waitForQuestion(_ id: InteractionID? = nil) async throws -> (InteractionID, SkillQuestion) {
        try await eventually("\(name) gets a question") { await self.pendingQuestion(id) != nil }
        return await pendingQuestion(id)!
    }

    func waitForProposal(revision: UInt32 = 1) async throws -> (InteractionID, SkillProposal) {
        try await eventually("\(name) gets proposal \(revision)") {
            await self.coordinator.all().contains { $0.state == .proposed && $0.proposalRevision == revision }
        }
        let interaction = await coordinator.all().first { $0.state == .proposed && $0.proposalRevision == revision }!
        return (interaction.id, interaction.proposal!)
    }

    func waitForState(_ id: InteractionID? = nil, _ state: InteractionState, timeout: Duration = .seconds(5)) async throws {
        try await eventually("\(name) reaches \(state)", timeout: timeout) {
            await self.coordinator.all().contains { (id == nil || $0.id == id) && $0.state == state }
        }
    }

    func reply(_ id: InteractionID, question: UInt32, _ slots: [TimeSlot]) async throws {
        try await service.answer(id, with: .reply(question: question, .slots(slots)))
    }

    func accept(_ id: InteractionID, revision: UInt32 = 1) async throws {
        try await service.answer(id, with: .accept(proposal: revision))
    }
}

/// Phones on one Loopback hub, every pair paired, with every frame recorded.
final class World: Sendable {
    let hub = LoopbackHub()
    let clock = TestClock()
    let phones: Mutex<[Phone]> = Mutex([])
    let frames: Mutex<[Frame]> = Mutex([])
    private let observer: Mutex<Task<Void, Never>?> = Mutex(nil)

    func phone(
        _ name: String, calendar: FakeCalendarStore = FakeCalendarStore(), use: CalendarUse = .useMyCalendar,
        policy: any PolicyEngine = FixedPolicyEngine(.allow), consent: any ConsentProvider = ScriptedConsentProvider(.approved)
    ) -> Phone {
        let phone = Phone(name: name, hub: hub, calendar: calendar, use: use, policy: policy, consent: consent, clock: clock)
        phones.withLock { $0.append(phone) }
        return phone
    }

    func start(pairAll: Bool = true) async throws {
        let deliveries = await hub.deliveries()
        observer.withLock { $0 = Task { for await delivery in deliveries { self.frames.withLock { $0.append(delivery.frame) } } } }
        let all = phones.withLock { $0 }
        if pairAll { for a in all { for b in all where a !== b { try await a.pair(with: b) } } }
        for phone in all { try await phone.start() }
        for phone in all { try await phone.greet(all) }
        try await eventually("hellos delivered") { self.envelopes.filter { $0.body.kind == .hello }.count == all.count * (all.count - 1) }
    }

    func stop() async {
        for phone in phones.withLock({ $0 }) { await phone.stop() }
        observer.withLock { $0?.cancel() }
    }

    var envelopes: [Envelope] { frames.withLock { $0 }.compactMap { try? EnvelopeCodec().decode($0.bytes) } }
    var wireText: String { frames.withLock { $0 }.map { String(decoding: $0.bytes, as: UTF8.self) }.joined(separator: "\n") }
}

func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for \(what)")
    throw CancellationError()
}

extension Interaction {
    var timeSlot: TimeSlot? { artifacts.lazy.compactMap { if case .timeSlot(let slot) = $0 { slot } else { nil } }.first }
}

extension SkillQuestion {
    var slots: [TimeSlot] { if case .slots(let slots) = candidates { slots } else { [] } }
}
