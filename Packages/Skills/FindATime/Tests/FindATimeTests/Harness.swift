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
/// Most tests pin short waits so a test moves the clock by an hour or two.
let fastConfiguration = FindATimeConfiguration(
    retryInterval: .milliseconds(20), maxAttempts: 50,
    answerWait: .seconds(30 * 60), confirmWait: .seconds(60 * 60), inviteeLifetime: .seconds(6 * 60 * 60)
)
/// The shipped waits, with fast retries.
let shippedWaits = FindATimeConfiguration(retryInterval: .milliseconds(20), maxAttempts: 50)

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
/// every event to its interactions and keeps what it could not apply.
///
/// Each read, apply, and write happens without suspending, so two events
/// can never interleave and lose an update (a consent approval saved over a
/// withdrawal, say). Lane A's coordinator needs the same property.
actor Coordinator {
    private var items: [InteractionID: Interaction] = [:]
    private(set) var log: [SkillEvent] = []
    private(set) var rejected: [SkillEvent] = []
    private(set) var produced: [InteractionID: [Artifact]] = [:]
    private(set) var consents: [InteractionEvent] = []
    private var queued: [InteractionID: [InteractionEvent]] = [:]

    func consume(_ event: SkillEvent) {
        log.append(event)
        switch event {
        case .incoming(let id, let conversation, let from, _):
            items[id] = Interaction(
                id: id, conversation: conversation, skill: FindATimeSkill.ref, role: .invitee,
                participants: [from], createdAt: Timestamp(Date())
            )
        case .lifecycle(let id, let lifecycle):
            guard var interaction = items[id] else { rejected.append(event); return }
            // Progress during a consent suspension waits for the step to
            // resume (ADR 0011, amendment 15).
            if case .awaitingConsent = interaction.state, Self.waitsForConsent(lifecycle) {
                queued[id, default: []].append(lifecycle)
                return
            }
            do {
                try interaction.apply(lifecycle, at: Timestamp(Date()))
                items[id] = interaction
            } catch {
                rejected.append(event)
            }
        case .produced(let id, let artifact):
            produced[id, default: []].append(artifact)
            items[id]?.record(artifact)
        }
    }

    private static func waitsForConsent(_ event: InteractionEvent) -> Bool {
        switch event {
        case .ownerNeeded, .proposalReady, .everyoneConfirmed: true
        default: false
        }
    }

    private func drainQueue(_ id: InteractionID) {
        guard var interaction = items[id] else { return }
        if case .awaitingConsent = interaction.state { return }
        for event in queued.removeValue(forKey: id) ?? [] {
            do { try interaction.apply(event, at: Timestamp(Date())) } catch { rejected.append(.lifecycle(id, event)) }
        }
        items[id] = interaction
    }

    func begin(_ interaction: Interaction) { items[interaction.id] = interaction }

    /// At launch the coordinator closes consent requests whose sheets died
    /// with the old process, before `restore(_:)` (ADR 0011, amendment 15).
    func closeDeadSheets() {
        for (id, var interaction) in items where !interaction.pendingConsents.isEmpty {
            for request in interaction.pendingConsents.sorted() {
                try? interaction.apply(.consentCancelled(request: request), at: Timestamp(Date()))
            }
            items[id] = interaction
            drainQueue(id)
        }
    }

    /// Opens a consent request on the interaction the send names
    /// (`Disclosure.interaction`, Core v2.1). The interaction may not be
    /// recorded yet when the sheet opens, so it waits briefly for it.
    func openConsent(_ id: InteractionID?) async -> UInt32? {
        guard let id else { return nil }
        for _ in 0..<200 {
            if var interaction = items[id] {
                if interaction.state.isFinal { return nil }
                let request = interaction.consentWatermark + 1
                if (try? interaction.apply(.consentNeeded(request: request), at: Timestamp(Date()))) != nil {
                    items[id] = interaction
                    consents.append(.consentNeeded(request: request))
                    return request
                }
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    /// Closes the request the sheet opened: given on approval, the owner's
    /// pass on a decline.
    func closeConsent(_ id: InteractionID?, request: UInt32?, approved: Bool) {
        guard let id, let request, var interaction = items[id], !interaction.state.isFinal else { return }
        let event: InteractionEvent = approved ? .consentGiven(request: request) : .ownerPassed
        do {
            try interaction.apply(event, at: Timestamp(Date()))
            items[id] = interaction
            consents.append(event)
        } catch {
            rejected.append(.lifecycle(id, event))
        }
        drainQueue(id)
    }

    func all() -> [Interaction] { items.values.sorted { $0.createdAt < $1.createdAt } }
    func interaction(_ id: InteractionID) -> Interaction? { items[id] }
    func invitee() -> Interaction? { all().first { $0.role == .invitee } }
    func initiator() -> Interaction? { all().first { $0.role == .initiator } }
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

/// An owner who leaves the consent sheet open until the test answers it.
actor HeldConsent: ConsentProvider {
    private var waiting: [CheckedContinuation<ConsentOutcome, Never>] = []
    private(set) var asked = 0

    func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        asked += 1
        return await withCheckedContinuation { waiting.append($0) }
    }

    func answerAll(_ outcome: ConsentOutcome) {
        for continuation in waiting { continuation.resume(returning: outcome) }
        waiting = []
    }
}

/// A policy that asks for consent on every skill message.
let alwaysAsk = FixedPolicyEngine(decide: { message in
    guard message.envelope.skill != nil else { return .allow }
    return .needsConsent(Disclosure(
        recipient: message.envelope.recipient, recipientModel: nil, items: [],
        conversation: message.envelope.conversation, skill: message.envelope.skill, interaction: message.context.interaction
    ))
})

/// A policy that holds chosen sends until the test opens the gate, then
/// denies them, so a denial can arrive after its step was superseded. Every
/// other send is allowed.
actor HeldDenial: PolicyEngine {
    private let holds: @Sendable (OutboundMessage) -> Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var held = 0

    init(_ holds: @escaping @Sendable (OutboundMessage) -> Bool) { self.holds = holds }

    func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        guard holds(message) else { return .allow }
        held += 1
        await withCheckedContinuation { waiting.append($0) }
        return .deny(PolicyViolation(rule: "test.held"))
    }

    func release() {
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// A conversation ledger whose retirements a test can hold or make fail,
/// around the in-memory one (ADR 0021).
actor ControlledLedger: ConversationLedger {
    struct RetireFailed: Error {}

    let inner: InMemoryConversationLedger
    private var holding = false
    private var failing = false
    private var abandoning = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var retireCalls = 0

    init(_ inner: InMemoryConversationLedger) { self.inner = inner }

    func hold() { holding = true }
    func failRetirements(_ fail: Bool) { failing = fail }
    func release() {
        holding = false
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    /// Ends every held retirement without recording it, as if the process
    /// had died while it was waiting.
    func abandonHeld() {
        abandoning = true
        release()
    }

    func isRetired(_ conversation: ConversationID) async throws -> Bool { try await inner.isRetired(conversation) }

    func retire(_ conversation: ConversationID) async throws {
        retireCalls += 1
        if holding {
            await withCheckedContinuation { waiting.append($0) }
            if abandoning {
                abandoning = false
                throw RetireFailed()
            }
        }
        if failing { throw RetireFailed() }
        try await inner.retire(conversation)
    }

    func reserve(_ candidates: [IssueValue], issue: IssueKey, to peer: PeerID, in conversation: ConversationID) async throws -> Bool {
        try await inner.reserve(candidates, issue: issue, to: peer, in: conversation)
    }
}

/// An Outbox observer that holds `didSend` for chosen envelopes until the
/// test releases them: the send has left, but Outbox has not returned to
/// the service yet, as with a slow audit journal (issue #105).
actor HoldingObserver: OutboxObserver {
    private let holds: @Sendable (Envelope) -> Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var held = 0

    init(_ holds: @escaping @Sendable (Envelope) -> Bool) { self.holds = holds }

    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {
        guard !released, holds(envelope) else { return }
        held += 1
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        released = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// The app's consent provider around a scripted owner.
struct LifecycleConsent: ConsentProvider {
    let owner: any ConsentProvider
    let coordinator: Coordinator

    func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        let request = await coordinator.openConsent(disclosure.interaction)
        let outcome = await owner.requestConsent(for: disclosure)
        await coordinator.closeConsent(disclosure.interaction, request: request, approved: outcome == .approved)
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
    /// Kept across restarts, as the app persists it, so a relaunched Outbox
    /// never reuses a sequence number (Core v2.1).
    let sequences = InMemorySentSequenceStore()
    /// The phone's one conversation ledger, kept across restarts as the app
    /// persists it, shared by its Outbox and the service (ADR 0021).
    let conversations = InMemoryConversationLedger()
    /// What the Outbox and the service use: `conversations`, or a test's
    /// wrapper around it.
    let ledger: any ConversationLedger
    let configuration: FindATimeConfiguration
    let observer: (any OutboxObserver)?
    let clock: TestClock
    let standing: ConstraintSet
    private let state: Mutex<(service: FindATimeService?, outbox: Outbox?, coordinator: Coordinator, tasks: [Task<Void, Never>])>
    private let inboxLoop: Mutex<Task<Void, Never>?> = Mutex(nil)

    var id: PeerID { key.peerID }
    var service: FindATimeService { state.withLock { $0.service! } }
    var coordinator: Coordinator { state.withLock { $0.coordinator } }

    init(name: String, hub: LoopbackHub, calendar: FakeCalendarStore, use: CalendarUse = .useMyCalendar,
         policy: any PolicyEngine = FixedPolicyEngine(.allow), consent: any ConsentProvider = ScriptedConsentProvider(.approved),
         standing: ConstraintSet = .empty, policyWithFriends: (@Sendable (any PairedPeerStore) -> any PolicyEngine)? = nil,
         ledger: (@Sendable (InMemoryConversationLedger) -> any ConversationLedger)? = nil,
         configuration: FindATimeConfiguration = fastConfiguration, observer: (any OutboxObserver)? = nil, clock: TestClock) {
        self.name = name
        key = try! IdentityPublicKey(bytes: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
        transport = LossyTransport(LoopbackTransport(localPeer: key.peerID, hub: hub))
        self.calendar = calendar
        self.use = Mutex(use)
        self.policy = policyWithFriends?(peers) ?? policy
        self.ledger = ledger?(conversations) ?? conversations
        self.configuration = configuration
        self.observer = observer
        self.consent = consent
        self.clock = clock
        self.standing = standing
        state = Mutex((nil, nil, Coordinator(), []))
    }

    /// Builds a service and its coordinator loop. Called at start and again
    /// to simulate an app restart.
    func makeService(configuration: FindATimeConfiguration = fastConfiguration) {
        let outbox = Outbox(transport: transport, policy: policy, consent: LifecycleConsent(owner: consent, coordinator: coordinator),
                            observer: observer, sequences: sequences, ledger: ledger)
        let availability = OwnerAvailability.standard(calendar: calendar, use: { self.use.withLock { $0 } })
        let service = FindATimeService(
            localPeer: id, outbox: outbox, conversations: ledger, pairedPeers: peers, availability: availability, checkpoints: checkpoints,
            clock: clock.clock, timeZone: T.utc, configuration: configuration,
            standingRules: { [standing] in standing }
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
    func send(_ body: MessageBody, to peer: Phone, conversation: ConversationID, skill: SkillRef? = FindATimeSkill.ref,
              mode: SendMode = .invite, chainedFrom: ConversationID? = nil, answering: Query? = nil) async throws -> Envelope {
        let outbox = state.withLock { $0.outbox! }
        return try await outbox.send(body, to: peer.id, conversation: conversation, context: OutboundContext(answering: answering),
                                     skill: skill, mode: skill == nil ? nil : mode, chainedFrom: chainedFrom)
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
        makeService(configuration: configuration)
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
    func restart(configuration: FindATimeConfiguration? = nil) async {
        let old = service
        await old.flushCheckpoints()
        await old.shutdown()
        makeService(configuration: configuration ?? self.configuration)
        await coordinator.closeDeadSheets()
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
        with friends: [Phone], range: [TimeSlot]? = [T.slot(8, 24)], also: [Constraint] = [], daily: (Int, Int)? = nil,
        activity: String? = "stats", expiresIn hours: Double = 48, chainedFrom: ConversationID? = nil, mode: SendMode = .invite
    ) async throws -> InteractionID {
        var constraints: [IssueKey: [Constraint]] = [.time: (try range.map { [try Constraint(.within($0))] } ?? []) + also]
        if constraints[.time]!.isEmpty && daily == nil { constraints[.time] = nil }
        if let daily { constraints[.time, default: []].append(try Constraint(.dailyWindow(from: daily.0, to: daily.1))) }
        if let activity { constraints[.activity] = [try Constraint(.prefers(liked: [Keyword(activity)], avoided: []), strength: .soft)] }
        let intent = SkillIntent(
            skill: FindATimeSkill.ref, rules: OwnerRules(constraints: try ConstraintSet(constraints)),
            audience: .picked(friends.map(\.id)), mode: mode, expiresAt: Timestamp(clock.now.addingTimeInterval(hours * 3600))
        )
        // As the coordinator does (ADR 0011, amendment 13): apply `.started`
        // when the owner sends, then start; if start throws, apply `.failed`.
        var interaction = Interaction(skill: FindATimeSkill.ref, role: .initiator, participants: friends.map(\.id), createdAt: Timestamp(Date()))
        try interaction.apply(.started, at: Timestamp(Date()))
        await coordinator.begin(interaction)
        do {
            try await service.start(SkillRequest(
                interaction: interaction.id, conversation: interaction.conversation, intent: intent,
                participants: friends.map(\.id), chainedFrom: chainedFrom
            ))
        } catch {
            try interaction.apply(.failed, at: Timestamp(Date()))
            await coordinator.begin(interaction)
            throw error
        }
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
            // A plan's artifacts follow the state change as their own events.
            await self.coordinator.all().contains {
                (id == nil || $0.id == id) && $0.state == state && (state != .planned || ($0.plan != nil && $0.timeSlot != nil))
            }
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
        policy: any PolicyEngine = FixedPolicyEngine(.allow), consent: any ConsentProvider = ScriptedConsentProvider(.approved),
        standing: ConstraintSet = .empty,
        policyWithFriends: (@Sendable (any PairedPeerStore) -> any PolicyEngine)? = nil,
        ledger: (@Sendable (InMemoryConversationLedger) -> any ConversationLedger)? = nil,
        configuration: FindATimeConfiguration = fastConfiguration,
        observer: (any OutboxObserver)? = nil
    ) -> Phone {
        let phone = Phone(name: name, hub: hub, calendar: calendar, use: use, policy: policy, consent: consent,
                          standing: standing, policyWithFriends: policyWithFriends, ledger: ledger,
                          configuration: configuration, observer: observer, clock: clock)
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
