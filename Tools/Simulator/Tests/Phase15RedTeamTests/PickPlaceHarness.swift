import Foundation
import PickAPlace
import SimulatorKit
import StarlingCore
import StarlingFakes
import StarlingPolicy
import Synchronization
import Testing

/// Routes only messages already authenticated and accepted by Simulation's
/// sole Inbox. No second consumer reads Transport.events.
actor PlaceRelay: AgentBehavior {
    var service: (any SkillService)?
    private(set) var handled: Set<MessageID> = []
    private var loseAnswer = false
    private(set) var lostAnswers: [MessageID] = []
    func attach(_ service: (any SkillService)?) { self.service = service }
    func loseNextAnswer() { loseAnswer = true }
    func respond(to envelope: Envelope, in agent: SimulatedAgent) async {
        if loseAnswer && envelope.body.kind == .answer {
            loseAnswer = false
            lostAnswers.append(envelope.id)
            handled.insert(envelope.id)
            return
        }
        await service?.handle(.message(envelope))
        handled.insert(envelope.id)
    }
}

actor PlaceTestClock {
    nonisolated let instant: Mutex<Date>
    private let start: Date
    private(set) var elapsed: Duration = .zero
    private var sleepers: [UUID: (Duration, CheckedContinuation<Void, any Error>)] = [:]
    var due: Set<Duration> { Set(sleepers.values.map(\.0)) }
    init(now: Date = P15.date) { start = now; instant = Mutex(now) }
    nonisolated var clock: PickAPlaceClock {
        PickAPlaceClock(now: { self.instant.withLock { $0 } }, sleep: { try await self.sleep($0) })
    }
    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        guard duration > .zero else { return }
        let id = UUID()
        let deadline = elapsed + duration
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { sleepers[id] = (deadline, $0) }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
    func advance(_ seconds: TimeInterval) {
        advance(to: elapsed + .seconds(seconds))
    }
    func advance(to target: Duration) {
        precondition(target >= elapsed)
        elapsed = target
        let parts = target.components
        instant.withLock { $0 = start.addingTimeInterval(Double(parts.seconds) + Double(parts.attoseconds) / 1e18) }
        for (id, sleeper) in sleepers.sorted(by: { $0.value.0 < $1.value.0 }) where sleeper.0 <= elapsed {
            sleepers.removeValue(forKey: id)?.1.resume()
        }
    }
    func waitForSleeps(_ deadlines: Set<Duration>) async throws {
        try await P15.eventually("service arms virtual deadlines \(deadlines)") {
            self.due.isSuperset(of: deadlines)
        }
    }
}

actor PlaceTestMaps: PlaceSearching {
    var values: [PlaceChoice: PlaceFacts] = [:]
    private(set) var lookedUp: [PlaceChoice] = []
    private(set) var searches = 0
    func set(_ candidates: [PlaceCandidate]) { for candidate in candidates { values[candidate.choice] = candidate.facts } }
    func search(_ what: String, in region: SearchRegion, limit: Int) async throws -> [PlaceCandidate] {
        searches += 1
        return []
    }
    func facts(for place: PlaceChoice) async throws -> PlaceFacts? {
        lookedUp.append(place)
        // The test provider, like Maps, checks the identifier's actual name.
        return values.first { $0.key.mapItemID != nil && $0.key.mapItemID == place.mapItemID }?.value
    }
}

/// The fixture applies Core lifecycle events, but is not the app coordinator.
/// App consent queuing, disk recovery, and chain routing stay open in #49.
actor PlaceEvents {
    let skill: SkillRef
    let store = InMemoryInteractionStore()
    private(set) var received: [SkillEvent] = []
    private(set) var invalid: [String] = []
    init(skill: SkillRef = PickAPlaceSkill.ref) { self.skill = skill }
    func add(_ interaction: Interaction) async throws { try await store.save(interaction) }
    func record(_ event: SkillEvent) async {
        received.append(event)
        do {
            switch event {
            case .incoming(let id, let conversation, let from, let hint):
                var interaction = Interaction(id: id, conversation: conversation, skill: skill,
                    role: .invitee, participants: [from], createdAt: P15.now)
                try interaction.setFriendChainHint(hint)
                try await store.save(interaction)
            case .lifecycle(let id, let lifecycle):
                guard var interaction = try await store.interaction(id) else { invalid.append("Unknown interaction"); return }
                try interaction.apply(lifecycle, at: P15.now)
                try await store.save(interaction)
            case .produced(let id, let artifact):
                guard var interaction = try await store.interaction(id) else { invalid.append("Unknown artifact interaction"); return }
                interaction.record(artifact)
                try await store.save(interaction)
            }
        } catch { invalid.append(String(describing: error)) }
    }
    func interaction(_ conversation: ConversationID) async throws -> Interaction? { try await store.interaction(conversation: conversation) }
}

actor PlaceConversationLedger: ConversationLedger {
    let base = InMemoryConversationLedger()
    var hold = false
    var fail = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var retiring: [ConversationID] = []
    private(set) var checked: Set<ConversationID> = []
    private(set) var reservations: [(ConversationID, [IssueValue])] = []
    func gateRetirement(failing: Bool) { hold = true; fail = failing }
    func release() { hold = false; for waiter in releaseWaiters { waiter.resume() }; releaseWaiters = [] }
    func isRetired(_ conversation: ConversationID) async throws -> Bool {
        let result = try await base.isRetired(conversation)
        checked.insert(conversation)
        return result
    }
    func retire(_ conversation: ConversationID) async throws {
        retiring.append(conversation)
        if hold { await withCheckedContinuation { releaseWaiters.append($0) } }
        if fail { throw LedgerUnavailable() }
        try await base.retire(conversation)
    }
    func reserve(_ candidates: [IssueValue], issue: IssueKey, to peer: PeerID, in conversation: ConversationID) async throws -> Bool {
        reservations.append((conversation, candidates))
        return try await base.reserve(candidates, issue: issue, to: peer, in: conversation)
    }
}

/// One real service and Outbox, over Simulation's existing secure channel.
final class PlacePhone: Sendable {
    let agent: SimulatedAgent
    let relay: PlaceRelay
    let peers = InMemoryPairedPeerStore()
    let staged = StagedCandidates()
    let maps = PlaceTestMaps()
    let clock = PlaceTestClock()
    let events = PlaceEvents()
    let conversations = PlaceConversationLedger()
    let ledger: any PickAPlaceLedger
    let observer = RecordingOutboxObserver()
    let consent = ScriptedConsentProvider(.approved)
    let outbox: Outbox
    let policy: any PolicyEngine
    let limits: ConstraintSet
    private let current = Mutex<PickAPlaceService?>(nil)
    private let eventTasks = Mutex<[Task<Void, Never>]>([])
    var id: PeerID { agent.id }
    var service: PickAPlaceService { current.withLock { $0! } }
    static let configuration = PickAPlaceConfiguration(retryInterval: .seconds(5), maxRetryInterval: .seconds(10),
        answerWindow: .seconds(20), confirmWindow: .seconds(30))

    init(agent: SimulatedAgent, relay: PlaceRelay, choices: [PrivacyTopic: SharingChoice] = [.place: .share, .people: .share],
         limits: ConstraintSet = .empty, onlyOnDevice: Bool = false, ledger: any PickAPlaceLedger = InMemoryPickAPlaceLedger()) throws {
        self.agent = agent; self.relay = relay; self.limits = limits; self.ledger = ledger
        policy = DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty,
            disclosure: try PrivacySettings(choices).disclosureRules), onlyOnDeviceAgents: onlyOnDevice, pairedPeers: peers)
        outbox = Outbox(transport: try #require(agent.secureTransport), policy: policy, consent: consent,
            observer: observer, sequences: InMemorySentSequenceStore(), ledger: conversations, now: { P15.date })
    }

    func boot(restore: Bool = false) async throws {
        let limits = limits
        let fresh = PickAPlaceService(localPeer: id, outbox: outbox, pairedPeers: peers, candidates: staged,
            maps: maps, ownerLimits: { limits }, ledger: ledger, conversations: conversations, plans: { _ in nil },
            clock: clock.clock, configuration: Self.configuration)
        current.withLock { $0 = fresh }
        let events = events
        eventTasks.withLock { $0.append(Task { for await event in fresh.events { await events.record(event) } }) }
        // These are actual hello envelopes that traversed the sole Inbox.
        for envelope in await agent.received where envelope.body.kind == .hello { await fresh.handle(.message(envelope)) }
        if restore { await fresh.restore(try await events.store.all()) }
        await relay.attach(fresh)
    }
    func restart() async throws {
        await relay.attach(nil)
        await service.shutdown()
        try await boot(restore: true)
    }
    func stop() async {
        await relay.attach(nil)
        await service.shutdown()
        await conversations.release()
        for task in eventTasks.withLock({ $0 }) { task.cancel() }
    }
    func organize(_ candidates: [PlaceCandidate], participants: [PeerID], audience: Audience? = nil,
                   inputs: [Artifact] = [], parent: ConversationID? = nil) async throws -> Interaction {
        var interaction = Interaction(skill: PickAPlaceSkill.ref, role: .initiator, participants: participants, createdAt: P15.now)
        try interaction.apply(.started, at: P15.now)
        try await events.add(interaction)
        await staged.stage(candidates, for: interaction.id)
        let intent = SkillIntent(skill: PickAPlaceSkill.ref, rules: OwnerRules(constraints: limits),
            audience: audience ?? .picked(participants), mode: .invite, expiresAt: Timestamp(P15.date.addingTimeInterval(300)))
        try await service.start(SkillRequest(interaction: interaction.id, conversation: interaction.conversation,
            intent: intent, participants: participants, inputs: inputs, chainedFrom: parent))
        return interaction
    }
    @discardableResult
    func send(_ body: MessageBody, to peer: PeerID, conversation: ConversationID, context: OutboundContext = .empty,
              skill: SkillRef = PickAPlaceSkill.ref, mode: SendMode = .invite, parent: ConversationID? = nil) async throws -> Envelope {
        try await outbox.send(body, to: peer, conversation: conversation, recipientCard: P15.card([PickAPlaceSkill.ref]),
            context: context, skill: skill, mode: mode, chainedFrom: parent)
    }
    func wait(_ state: InteractionState, in conversation: ConversationID,
              retrying organizer: PlacePhone? = nil) async throws -> Interaction {
        // A frozen retry clock can strand a best-effort exchange even when
        // the host gets arbitrarily long to schedule it. Only explicit
        // callers drive retries, strictly before the answer window closes.
        let limit = if let organizer { await organizer.clock.elapsed + Self.configuration.answerWindow - Self.configuration.retryInterval }
                    else { Duration.zero }
        try await P15.eventually("Pick a place reaches \(state)") {
            if try await self.events.interaction(conversation)?.state == state { return true }
            if let organizer, let next = await organizer.clock.due.filter({ $0 <= limit }).min() {
                await organizer.clock.advance(to: next)
            }
            return false
        }
        return try #require(await events.interaction(conversation))
    }
    func accept(_ conversation: ConversationID) async throws {
        let interaction = try #require(await events.interaction(conversation))
        try await service.answer(interaction.id, with: .accept(proposal: #require(interaction.proposalRevision)))
    }
    func sent(_ conversation: ConversationID) async -> [Envelope] {
        await observer.records.map(\.envelope).filter { $0.conversation == conversation }
    }
}

struct PlaceWorld: Sendable {
    let simulation: Simulation
    let phones: [PlacePhone]
    static func make(count: Int = 3, neverOnInvitee: Bool = false, limits: ConstraintSet = .empty,
                     onlyOnDevice: Bool = false, cloudLast: Bool = false,
                     inviteeLedger: any PickAPlaceLedger = InMemoryPickAPlaceLedger()) async throws -> Self {
        let simulation = Simulation(now: { P15.date }, security: .secureChannel)
        var phones: [PlacePhone] = []
        for index in 0..<count {
            let relay = PlaceRelay()
            let agent = try await simulation.addAgent("Friend \(index)", behavior: relay,
                model: cloudLast && index == count - 1 ? .thirdPartyCloud(provider: "test") : .onDevice)
            let choices: [PrivacyTopic: SharingChoice] = index == 1 && neverOnInvitee
                ? [.place: .never, .people: .never, .budget: .never, .diet: .never, .location: .never, .calendarDetails: .never]
                : [.place: .share, .people: .share]
            phones.append(try PlacePhone(agent: agent, relay: relay, choices: choices,
                limits: index == 1 ? limits : .empty, onlyOnDevice: index == 0 && onlyOnDevice,
                ledger: index == 1 ? inviteeLedger : InMemoryPickAPlaceLedger()))
        }
        try await P15.waitForMesh(simulation)
        for phone in phones {
            let secure = try #require(phone.agent.secureTransport)
            for other in phones where other.id != phone.id {
                let key = try #require(await secure.status(of: other.id).provenKey)
                try await phone.peers.save(PairedPeer(publicKey: key, nickname: other.agent.name, pairedAt: P15.now))
            }
        }
        // Advertise the actual descriptor over Outbox/Inbox before boot.
        for phone in phones {
            let card = try AgentCard(model: phone.agent.card.model, capabilities: [], skills: [PickAPlaceSkill.ref])
            for other in phones where other.id != phone.id {
                let hello = try await phone.outbox.send(.hello(card), to: other.id, conversation: ConversationID())
                try await P15.eventually("skill hello accepted") { await other.agent.received.contains(hello) }
            }
        }
        for phone in phones { try await phone.boot() }
        return Self(simulation: simulation, phones: phones)
    }
    func stop() async { for phone in phones { await phone.stop() }; await simulation.stop() }
    static func candidate(_ number: Int = 0, name: String? = nil, tier: PriceTier? = nil) throws -> PlaceCandidate {
        let choice = try PlaceChoice(name: PlaceName(name ?? "Boba \(number)"), mapItemID: "test-venue-\(number)")
        return PlaceCandidate(choice: choice, facts: PlaceFacts(name: choice.name, priceTier: tier))
    }
    func seed(_ candidates: [PlaceCandidate]) async { for phone in phones { await phone.maps.set(candidates) } }
    /// This waits for the real service's handle call, not a host-time guess.
    /// Spawned work needs its own event or send condition at the call site.
    func delivered(_ envelope: Envelope, to phone: PlacePhone) async throws {
        try await P15.eventually("service handled authenticated message") { await phone.relay.handled.contains(envelope.id) }
    }
}
