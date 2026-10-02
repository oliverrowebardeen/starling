import DownFor
import FindATime
import Foundation
import PickAPlace
import SimulatorKit
import StarlingAvailability
import StarlingAvailabilityFakes
import StarlingChaining
import StarlingCore
import StarlingFakes
import StarlingFeatures
import StarlingPolicy
import StarlingSwapPhotos
import Testing

actor AppIngress: AgentBehavior {
    private var input: AsyncStream<InboxEvent>.Continuation?
    func attach(_ input: AsyncStream<InboxEvent>.Continuation?) { self.input = input }
    func respond(to envelope: Envelope, in agent: SimulatedAgent) { input?.yield(.message(envelope)) }
}
actor AppNotices: PlanNotifier, LocalNetworkPrompter {
    private(set) var notices: [LifecycleNotice] = []
    private(set) var prompts = 0
    func post(_ notice: LifecycleNotice) { notices.append(notice) }
    func requestAuthorization() -> Bool { true }
    func prompt() { prompts += 1 }
}
actor AppLocation: LocationAccess {
    private(set) var requests = 0
    private(set) var reads = 0
    private var status = LocationAuthorization.notDetermined
    func authorization() -> LocationAuthorization { status }
    func requestWhenInUse() -> LocationAuthorization { requests += 1; status = .denied; return status }
    func currentCoordinate() throws -> Coordinate { reads += 1; throw LedgerUnavailable() }
}
actor AppModelProbe {
    private(set) var routes: [String] = []
    private(set) var intents: [String] = []
    private(set) var facts: [ProposalFacts] = []
    var parsed = ParsedIntent(constraints: .empty)
    var skill = SkillID.downFor
    func set(_ parsed: ParsedIntent, skill: SkillID = .downFor) { self.parsed = parsed; self.skill = skill }
    func route(_ text: String) -> SkillID { routes.append(text); return skill }
    func intent(_ text: String) -> ParsedIntent { intents.append(text); return parsed }
    func sentence(_ value: ProposalFacts) -> String { facts.append(value); return "A plan with friends" }
    nonisolated var model: ScriptedSkillModel {
        ScriptedSkillModel(onRoute: { text, _ in await self.route(text) },
            onIntent: { text, _ in await self.intent(text) }, onProposal: { await self.sentence($0) })
    }
}

/// The actual app graph with radio, model, calendar, and Maps boundaries
/// injected. The iOS composition factory is source-reviewed and gate-built;
/// this fixture does not claim to execute Keychain or system permission UI.
@MainActor
final class AppPhone {
    static let registry = try! SkillRegistry([DownFor.descriptor, FindATimeSkill.descriptor, PickAPlaceSkill.descriptor, SwapPhotos.descriptor])
    let agent: SimulatedAgent
    let ingress: AppIngress
    let directory = FileManager.default.temporaryDirectory.appending(path: "p15f-app-\(UUID().uuidString)")
    let peers = InMemoryPairedPeerStore()
    let notices = AppNotices()
    let model = AppModelProbe()
    let matcher = DownModelProbe()
    let calendar = FakeCalendarStore(status: .notDetermined, grantOnRequest: false)
    let location = AppLocation()
    let maps = PlaceTestMaps()
    let staged = StagedCandidates()
    let clock = PlaceTestClock(now: Date())
    let wire = DownWire()
    var app: AppModel!
    var store: FileInteractionStore!
    var ledger: any ConversationLedger = InMemoryConversationLedger()
    var journal: FileEgressJournal!
    var sequences: FileSentSequenceStore!
    var downStore: FileDownForRequestStore!
    var input: AsyncStream<InboxEvent>.Continuation?
    let flags: SkillFlags
    var id: PeerID { agent.id }
    var outbox: Outbox { app.outbox! }
    init(agent: SimulatedAgent, ingress: AppIngress, flags: SkillFlags) {
        self.agent = agent; self.ingress = ingress; self.flags = flags
    }
    func file(_ name: String) -> JSONFile { JSONFile(url: directory.appending(path: name)) }
    func boot(ledgerOverride: (any ConversationLedger)? = nil) async throws {
        store = FileInteractionStore(file: file("interactions.json"))
        ledger = ledgerOverride ?? FileConversationLedger(file: file("ledger.json"))
        journal = FileEgressJournal(file: file("journal.json"))
        sequences = FileSentSequenceStore(file: file("sequences.json"))
        downStore = FileDownForRequestStore(file: file("requests.json"))
        let (events, continuation) = AsyncStream.makeStream(of: InboxEvent.self)
        input = continuation
        let choices = OwnerChoices(), id = id, peers = peers, ledger = ledger, store = store!
        let calendar = calendar, staged = staged, maps = maps, downStore = downStore!, matcher = matcher
        let clock = clock.clock
        let rules = FileRulesStore(url: file("rules.json").url)
        let checkpoints = FileFindATimeCheckpoints(directory: directory.appending(path: "time"))
        let secure = try #require(agent.secureTransport)
        app = AppModel(services: AppServices(skillModel: model.model, registry: Self.registry, flags: flags,
            makeSkills: { outbox in [
                DownForService(localPeer: id, outbox: outbox, model: matcher.model, psi: InsecurePSIStub(), ledger: ledger,
                    store: downStore, pairedPeers: peers, clock: SkillClock(now: clock.now, sleep: clock.sleep), timeZone: TimeZone(secondsFromGMT: 0)!,
                    configuration: DownForConfiguration(maxAttempts: 30)),
                FindATimeService(localPeer: id, outbox: outbox, conversations: ledger, pairedPeers: peers,
                    availability: .standard(calendar: calendar, use: { await choices.calendarUse() }), checkpoints: checkpoints,
                    clock: FindATimeClock(now: clock.now, sleep: clock.sleep), timeZone: TimeZone(secondsFromGMT: 0)!, configuration: FindATimeConfiguration(dailyFrom: 0, dailyTo: 1440), isTurnedOn: { await choices.isOn(.findATime) },
                    standingRules: { await choices.standingConstraints() }),
                PickAPlaceService(localPeer: id, outbox: outbox, pairedPeers: peers, candidates: staged, maps: maps,
                    ownerLimits: { (try? await rules.load())?.rules.constraints ?? .empty }, ledger: InMemoryPickAPlaceLedger(), conversations: ledger, clock: clock),
                SwapPhotosService(outbox: outbox, ledger: ledger, me: id, planLookup: { try? await store.interaction(conversation: $0)?.plan }),
            ] }, interactions: store, settings: FileOwnerSettingsStore(file: file("settings.json")), rules: rules, peers: peers,
            inboxEvents: events, makePolicy: { rules, only in DeterministicPolicyEngine(ownerRules: rules, onlyOnDeviceAgents: only, pairedPeers: peers) },
            auditLog: wire, sequences: sequences, ledger: ledger, egressJournal: journal,
            placeFinder: PlaceFinder(search: maps, location: location), stagedPlaces: staged, choices: choices,
            transport: AppBorrowedTransport(secure), agentLocality: .onDevice,
            notifier: notices, localNetwork: notices,
            permissions: [CalendarPermissionAccess(access: CalendarAccess(store: calendar)), LocationPermissionAccess(location: location)],
            cardsFile: file("cards.json"), notesFile: file("notes.json")))
        await app.start()
        await ingress.attach(continuation)
        var latest: [PeerID: Envelope] = [:]
        for envelope in await agent.received where envelope.body.kind == .hello { latest[envelope.sender] = envelope }
        // Restore only the last authenticated card, not the historical
        // bootstrap sequence that would temporarily overwrite the disk card.
        for envelope in latest.values { continuation.yield(.message(envelope)) }
        for peer in try await peers.all() { continuation.yield(.peerAvailable(peer.id)) }
        try await appEventually("bootstrap cards applied") {
            latest.allSatisfy { peer, envelope in
                if case .hello(let card) = envelope.body { self.app.cards.cards[peer] == card } else { false }
            }
        }
    }
    func restart() async throws {
        await ingress.attach(nil)
        input?.finish()
        await app.shutdown()
        try await boot()
    }
    func stop() async {
        await wire.release()
        await ingress.attach(nil)
        input?.finish()
        await app.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
    func approving() -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                if let request = app.consent.current { app.consent.answer(.approved, to: request.id) }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }
    static func slots() throws -> [TimeSlot] {
        let start = Date(timeIntervalSince1970: ceil(Date().addingTimeInterval(3600).timeIntervalSince1970 / 3600) * 3600)
        return [try TimeSlot(start: start, end: start.addingTimeInterval(3600))]
    }
    static func rules() throws -> ConstraintSet {
        try ConstraintSet([.time: [Constraint(.within(slots()))], .activity: [Constraint(.prefers(liked: [Keyword("boba")], avoided: []), strength: .soft)]])
    }
    func compose(_ skill: SkillID, with friends: [PeerID], mode: SendMode = .invite) async throws {
        app.composer.clear()
        await app.composer.choose(skill)
        app.composer.constraints = try Self.rules()
        app.composer.audience = .pick
        app.composer.picked = Set(friends)
        app.composer.mode = mode
    }
    func wait(_ state: InteractionState, _ id: InteractionID, retrying phones: [AppPhone] = []) async throws -> Interaction {
        var retryLimits: [Duration] = []
        let budget: Duration = app.lifecycle.interaction(id)?.skill.id == .pickAPlace ? .seconds(300) : .seconds(60)
        for phone in phones { retryLimits.append(await phone.clock.elapsed + budget) }
        try await appEventually("app interaction reaches \(state)") {
            if self.app.lifecycle.interaction(id)?.state == state { return true }
            // Replies can cross either phone's send bookkeeping. Drive
            // place retries through five virtual minutes, below its answer
            // window. Other skills retain their one-minute retry budget.
            for (phone, limit) in zip(phones, retryLimits) {
                if let next = await phone.clock.due.filter({ $0 <= limit }).min() {
                    await phone.clock.advance(to: next)
                }
            }
            return false
        }
        return try #require(app.lifecycle.interaction(id))
    }
    func incoming(_ conversation: ConversationID) async throws -> Interaction {
        try await appEventually("app installs invitee") { self.app.lifecycle.interaction(conversation: conversation) != nil }
        return try #require(app.lifecycle.interaction(conversation: conversation))
    }
    func accept(_ id: InteractionID) async throws {
        let item = try await wait(.proposed, id)
        let revision = try #require(item.proposalRevision)
        #expect(await app.lifecycle.answer(id, with: .accept(proposal: revision)))
    }
    func sent(_ conversation: ConversationID) async -> [Envelope] { await wire.records.map(\.envelope).filter { $0.conversation == conversation } }
}

@MainActor
struct AppWorld {
    let simulation: Simulation
    let phones: [AppPhone]
    static func make(_ count: Int = 3, flags: SkillFlags = .phase1_5) async throws -> Self {
        let simulation = Simulation(security: .secureChannel)
        var phones: [AppPhone] = []
        for index in 0..<count {
            let ingress = AppIngress()
            let agent = try await simulation.addAgent("Friend \(index)", behavior: ingress)
            phones.append(AppPhone(agent: agent, ingress: ingress, flags: flags))
        }
        phones.sort { $0.id < $1.id }
        try await P15.waitForMesh(simulation)
        for phone in phones {
            for other in phones where phone.id != other.id {
                let key = try #require(await phone.agent.secureTransport?.status(of: other.id).provenKey)
                try await phone.peers.save(PairedPeer(publicKey: key, nickname: other.agent.name, pairedAt: Timestamp(Date())))
            }
            try await phone.boot()
        }
        for phone in phones {
            for other in phones where phone.id != other.id {
                let hello = try await phone.outbox.send(.hello(#require(phone.app.agentCard)), to: other.id, conversation: ConversationID())
                try await appEventually("authenticated app hello") { await other.agent.received.contains(hello) }
                other.input?.yield(.message(hello))
            }
        }
        try await appEventually("all app support cards") {
            phones.allSatisfy { phone in
                phone.app.friends?.friends.count == count - 1 && phones.allSatisfy { other in
                    phone.id == other.id || phone.app.cards.cards[other.id] == other.app.agentCard
                }
            }
        }
        return Self(simulation: simulation, phones: phones)
    }
    func stop() async { for phone in phones { await phone.stop() }; await simulation.stop() }
}

@MainActor
func appEventually(_ description: String, _ predicate: @MainActor () async throws -> Bool) async throws {
    try await P15.eventually(description, predicate)
}

/// Simulation owns the authenticated channel and its sole Inbox across app
/// replacements. App shutdown tears down services, but leaves this test link
/// alive; this is an app/store restart, not a transport or process crash.
struct AppBorrowedTransport: Transport {
    let base: any Transport
    var kind: TransportKind { base.kind }
    var localPeer: PeerID { base.localPeer }
    let events = AsyncStream<TransportEvent> { $0.finish() }
    init(_ base: any Transport) { self.base = base }
    func start() async throws {}
    func send(_ frame: Frame, to peer: PeerID) async throws { try await base.send(frame, to: peer) }
    func stop() async {}
}
