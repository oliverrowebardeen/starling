import Foundation
import StarlingChaining
import StarlingChangePlan
import StarlingCore
import StarlingFakes
import Synchronization
import Testing

enum Fixtures {
    static let alex = try! PeerID(bytes: Data(repeating: 0xAA, count: 32))
    static let maya = try! PeerID(bytes: Data(repeating: 0xBB, count: 32))
    static let jake = try! PeerID(bytes: Data(repeating: 0xCC, count: 32))
    static let sam = try! PeerID(bytes: Data(repeating: 0xDD, count: 32))
    static let stranger = try! PeerID(bytes: Data(repeating: 0xEE, count: 32))
    /// A friend of Maya's, added to a plan in some tests.
    static let fay = try! PeerID(bytes: Data(repeating: 0x11, count: 32))
    /// 2026-10-02 19:00:00 UTC.
    static let start = Date(timeIntervalSince1970: 1_790_967_600)
    static func date(minutes: Int) -> Date { start.addingTimeInterval(Double(minutes) * 60) }
    static let boba = try! Keyword("boba")
    static let dinner = try! Keyword("dinner")
    /// Tonight 8:30 to 10:30, and the later slot a suggestion moves it to.
    static let tonight = try! TimeSlot(start: date(minutes: 90), end: date(minutes: 210))
    static let later = try! TimeSlot(start: date(minutes: 120), end: date(minutes: 240))
    static let registry = try! SkillRegistry(SampleSkills.all + [ChangePlan.descriptor])
    static let settings = SkillSettings(flags: SkillFlags(SkillFlags.phase1_5.enabled.union([.changePlan])))

    static func card(_ skills: [SkillDescriptor] = SampleSkills.all + [ChangePlan.descriptor]) -> AgentCard {
        try! AgentCard(model: .onDevice, capabilities: [], skills: skills.map(\.ref))
    }
}

/// A clock the tests move by hand. `sleep(until:)` waits until it is moved
/// there, or until the sleeping task is cancelled.
final class TestClock: Sendable {
    private struct Sleeper {
        let id: UUID
        let until: Date
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct State {
        var now: Date
        var sleepers: [Sleeper] = []
        var cancelled: Set<UUID> = []
    }
    private let state: Mutex<State>

    init(_ start: Date) { state = Mutex(State(now: start)) }

    var now: Date { state.withLock { $0.now } }

    func sleep(until date: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if state.now >= date { return .success(()) }
                    state.sleepers.append(Sleeper(id: id, until: date, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let sleeper: Sleeper? = state.withLock { state in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(to date: Date) {
        let due: [Sleeper] = state.withLock { state in
            state.now = date
            let due = state.sleepers.filter { $0.until <= date }
            state.sleepers.removeAll { $0.until <= date }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }
}

/// Anything the stand-in coordinator could not apply: a test fails on it.
actor Problems {
    private(set) var all: [String] = []
    func add(_ problem: String) { all.append(problem) }
}

/// A journal that can fail or hold the saves a test picks (issue #117,
/// review of PR #111 finding 2), over an in-memory one.
actor TestJournal: ChangePlanJournal {
    struct Unavailable: Error {}
    private let stored = InMemoryChangePlanJournal()
    private var failing: @Sendable (ChangePlanRecord) -> Bool = { _ in false }
    private var holding: @Sendable (ChangePlanRecord) -> Bool = { _ in false }
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Saves that match fail from now on.
    func fail(when matches: @escaping @Sendable (ChangePlanRecord) -> Bool) { failing = matches }
    /// Saves that match wait for `release()`.
    func hold(when matches: @escaping @Sendable (ChangePlanRecord) -> Bool) { holding = matches }
    var held: Int { waiting.count }
    /// The records whose saves are being held, in order.
    private(set) var heldRecords: [ChangePlanRecord] = []
    /// Writes a record at once, as the save a crash interrupted had.
    func saveNow(_ record: ChangePlanRecord) async throws { try await stored.save(record) }
    /// Later saves go through; those already held wait for `release()`.
    func stopHolding() { holding = { _ in false } }
    func release() {
        holding = { _ in false }
        for continuation in waiting { continuation.resume() }
        waiting = []
    }

    func save(_ record: ChangePlanRecord) async throws {
        if holding(record) {
            heldRecords.append(record)
            await withCheckedContinuation { waiting.append($0) }
        }
        if failing(record) { throw Unavailable() }
        try await stored.save(record)
    }
    func remove(_ key: UUID) async throws { try await stored.remove(key) }
    func records() async throws -> [ChangePlanRecord] { try await stored.records() }
}

final class Flag: Sendable {
    private let value = Mutex(false)
    var isSet: Bool { value.withLock { $0 } }
    func set(_ on: Bool) { value.withLock { $0 = on } }
}

extension ChangePlanRecord {
    var isAccepted: Bool { if case .accepted = self { true } else { false } }
    var isConfirming: Bool { if case .confirming = self { true } else { false } }
    var isApplied: Bool { if case .applied = self { true } else { false } }
    var isLeaving: Bool { if case .leaving = self { true } else { false } }
    var isDeparted: Bool { if case .departed = self { true } else { false } }
}

/// One phone: its Outbox, ledger, store, and Change the plan service, with a
/// stand-in lifecycle coordinator that applies every service event to a real
/// `Interaction`, as lane A's does.
final class Phone: Sendable {
    let me: PeerID
    let transport: RecordingTransport
    let ledger = InMemoryConversationLedger()
    let store: InMemoryInteractionStore
    let outbox: Outbox
    let journal = TestJournal()
    /// While set, the coordinator loses the plan updates it is given, as an
    /// app that quits before saving them would.
    let losingUpdates = Flag()
    /// While set, the coordinator loses every event it is given, as an app
    /// killed before it saved any of them would.
    let losingEverything = Flag()
    /// This phone's plan-change holds (ADR 0023), shared with every skill
    /// that changes plans. In memory: a relaunch starts with new ones.
    private let holdsBox = Mutex(PlanChangeHolds())
    var holds: PlanChangeHolds { holdsBox.withLock { $0 } }
    private let box: Mutex<ChangePlanService>
    var service: ChangePlanService { box.withLock { $0 } }
    let inbox: Inbox
    let problems = Problems()
    let clock: TestClock
    let consent: ScriptedConsentProvider
    private let consumer: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(_ me: PeerID, clock: TestClock, interactions: [Interaction], policy: (any PolicyEngine)? = nil,
         consent: ConsentOutcome = .approved, observer: ((InMemoryInteractionStore) -> (any OutboxObserver)?)? = nil) {
        self.me = me
        self.clock = clock
        transport = RecordingTransport(localPeer: me)
        store = InMemoryInteractionStore(interactions)
        self.consent = ScriptedConsentProvider(consent)
        outbox = Outbox(transport: transport, policy: policy ?? FixedPolicyEngine(.allow), consent: self.consent,
                        observer: observer?(store) ?? nil, ledger: ledger, now: { clock.now })
        box = Mutex(Self.makeService(outbox: outbox, ledger: ledger, journal: journal, holds: holdsBox.withLock { $0 }, me: me, store: store,
                                     clock: clock))
        inbox = Inbox(localPeer: me, now: { clock.now })
        let service = box.withLock { $0 }
        let (store, problems) = (store, problems)
        let (losing, everything) = (losingUpdates, losingEverything)
        consumer.withLock { $0 = Task { await Self.coordinate(service.events, store: store, problems: problems, clock: clock, losing: losing,
                                                              everything: everything) } }
    }

    private static func makeService(outbox: Outbox, ledger: InMemoryConversationLedger, journal: TestJournal, holds: PlanChangeHolds, me: PeerID,
                                    store: InMemoryInteractionStore, clock: TestClock) -> ChangePlanService {
        ChangePlanService(outbox: outbox, ledger: ledger, journal: journal, holds: holds, me: me, planLookup: { conversation in
            let all = (try? await store.all()) ?? []
            guard let holder = all.first(where: { ($0.state == .planned || $0.state == .done) && $0.plan?.origin == conversation }),
                  let plan = holder.plan
            else { return nil }
            return PlanRef(interaction: holder.id, conversation: holder.conversation, plan: plan)
        }, now: { clock.now }, sleep: { try await clock.sleep(until: $0) })
    }

    /// The app quits and relaunches: a new service over the same journal,
    /// Outbox, ledger, and store, with new holds, restored as the
    /// coordinator restores it. `before` runs first, as another skill
    /// restoring its own change would.
    func restart(before: (PlanChangeHolds) async -> Void = { _ in }) async {
        let old = service
        await old.shutdown()
        _ = await consumer.withLock { $0 }?.value
        let holds = PlanChangeHolds()
        holdsBox.withLock { $0 = holds }
        await before(holds)
        let fresh = Self.makeService(outbox: outbox, ledger: ledger, journal: journal, holds: holds, me: me, store: store, clock: clock)
        box.withLock { $0 = fresh }
        let (store, problems, clock, losing, everything) = (store, problems, clock, losingUpdates, losingEverything)
        losing.set(false)
        everything.set(false)
        consumer.withLock { $0 = Task { await Self.coordinate(fresh.events, store: store, problems: problems, clock: clock, losing: losing,
                                                              everything: everything) } }
        await fresh.restore(await all())
    }

    /// The stand-in coordinator.
    private static func coordinate(_ events: AsyncStream<SkillEvent>, store: InMemoryInteractionStore, problems: Problems, clock: TestClock,
                                   losing: Flag, everything: Flag) async {
        for await event in events {
            if everything.isSet { continue }
            let at = Timestamp(clock.now)
            do {
                switch event {
                case .incoming(let id, let conversation, let from, let chainedFrom):
                    var interaction = Interaction(id: id, conversation: conversation, skill: ChangePlan.descriptor.ref, role: .invitee,
                                                  participants: [from], createdAt: at)
                    let hint = IncomingChain.timelineParent(chainedFrom: chainedFrom, sender: from, interactions: try await store.all())
                    try interaction.setFriendChainHint(hint)
                    try await store.save(interaction)
                case .lifecycle(let id, let lifecycle):
                    guard var interaction = try await store.interaction(id) else {
                        await problems.add("no interaction for \(lifecycle)")
                        continue
                    }
                    try interaction.apply(lifecycle, at: at)
                    try await store.save(interaction)
                case .produced(let id, let artifact):
                    if losing.isSet { continue }
                    guard var interaction = try await store.interaction(id) else {
                        await problems.add("no interaction for \(artifact)")
                        continue
                    }
                    interaction.record(artifact)
                    try await store.save(interaction)
                }
            } catch {
                await problems.add("\(event): \(error)")
            }
        }
    }

    func interaction(_ id: InteractionID) async -> Interaction? { try? await store.interaction(id) }
    func all() async -> [Interaction] { (try? await store.all()) ?? [] }

    /// The plan this phone holds for `origin`, if it still stands.
    func plan(_ origin: ConversationID) async -> Plan? {
        await all().first { ($0.state == .planned || $0.state == .done) && $0.plan?.origin == origin }?.plan
    }

    /// Change the plan interactions this phone has for the plan, in start order.
    func changes() async -> [Interaction] { await all().filter { $0.skill.id == .changePlan } }

    func shutdown() async {
        await service.shutdown()
        _ = await consumer.withLock { $0 }?.value
    }
}

/// Phones that deliver each other's frames through their Inboxes, and a
/// record of who sent what to whom.
final class Network: Sendable {
    let phones: [PeerID: Phone]
    let clock: TestClock
    private let delivered = Mutex<[PeerID: Int]>([:])
    private let log = Mutex<[String]>([])
    /// Frames to lose, as "Alex > Maya: accept", each once, after letting
    /// `skipping` matching ones through.
    private let drops = Mutex<[(frame: String, skipping: Int)]>([])

    /// Loses a frame that matches, as an unreliable link would: the next one,
    /// or the one after `skipping` more go through.
    func drop(_ frame: String, skipping: Int = 0) { drops.withLock { $0.append((frame, skipping)) } }

    init(_ phones: [Phone], clock: TestClock) {
        self.phones = Dictionary(uniqueKeysWithValues: phones.map { ($0.me, $0) })
        self.clock = clock
    }

    static let names = [Fixtures.alex: "Alex", Fixtures.maya: "Maya", Fixtures.jake: "Jake", Fixtures.sam: "Sam", Fixtures.stranger: "Stranger",
                        Fixtures.fay: "Fay"]

    /// Every frame sent so far, as "Alex > Maya: propose".
    var transcript: [String] { log.withLock { $0 } }

    /// Delivers every frame not yet delivered, including any sent in reply,
    /// until nothing is left.
    func deliver() async {
        while true {
            var moved = false
            for phone in phones.values.sorted(by: { $0.me.description < $1.me.description }) {
                let sent = await phone.transport.sent
                let from = delivered.withLock { $0[phone.me, default: 0] }
                guard from < sent.count else { continue }
                delivered.withLock { $0[phone.me] = sent.count }
                for frame in sent[from...] {
                    moved = true
                    let kind = (try? EnvelopeCodec().decode(frame.frame.bytes)).map { "\($0.body.kind)" } ?? "?"
                    let line = "\(Self.names[phone.me] ?? "?") > \(Self.names[frame.peer] ?? "?"): \(kind)"
                    let lost = drops.withLock { drops in
                        guard let index = drops.firstIndex(where: { $0.frame == line }) else { return false }
                        if drops[index].skipping > 0 {
                            drops[index].skipping -= 1
                            return false
                        }
                        drops.remove(at: index)
                        return true
                    }
                    log.withLock { $0.append(lost ? line + " (lost)" : line) }
                    guard !lost, let to = phones[frame.peer] else { continue }
                    await to.service.handle(await to.inbox.process(.received(frame.frame, from: phone.me)))
                }
            }
            if !moved { return }
        }
    }

    /// Waits, without sleeping, until `condition` holds; fails the test if
    /// it never does.
    func until(_ what: String, _ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<20_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("never: \(what)")
        throw CancellationError()
    }

    /// Lets the coordinators catch up when nothing should change.
    func settle() async {
        for _ in 0..<500 { await Task.yield() }
    }

    func problems() async -> [String] {
        var all: [String] = []
        for phone in phones.values { all += await phone.problems.all }
        return all
    }

    func shutdown() async {
        for phone in phones.values { await phone.shutdown() }
    }
}

/// Alex, Maya, and Jake, each holding the same plan for boba tonight.
struct Group {
    let origin = ConversationID()
    let clock = TestClock(Fixtures.date(minutes: 10))
    let network: Network
    let roots: [PeerID: Interaction]

    init(people: [PeerID] = [Fixtures.alex, Fixtures.maya, Fixtures.jake], extra: [PeerID] = [], policy: (PeerID) -> (any PolicyEngine)? = { _ in nil },
         observer: @escaping (PeerID, InMemoryInteractionStore) -> (any OutboxObserver)? = { _, _ in nil }) {
        var roots: [PeerID: Interaction] = [:]
        var phones: [Phone] = []
        for person in people {
            roots[person] = try! Self.root(origin: origin, people: people, me: person)
            phones.append(Phone(person, clock: clock, interactions: [roots[person]!], policy: policy(person), observer: { observer(person, $0) }))
        }
        for person in extra { phones.append(Phone(person, clock: clock, interactions: [], policy: policy(person), observer: { observer(person, $0) })) }
        self.roots = roots
        network = Network(phones, clock: clock)
    }

    /// A Down for… plan on `me`'s phone, as everyone in it agreed.
    static func root(origin: ConversationID, people: [PeerID], me: PeerID) throws -> Interaction {
        let others = people.filter { $0 != me }
        let role: InteractionRole = me == people[0] ? .initiator : .invitee
        var root = Interaction(conversation: origin, skill: SampleSkills.downFor.ref, role: role, participants: others,
                               createdAt: Timestamp(Fixtures.date(minutes: 0)))
        if role == .initiator { try root.apply(.started, at: Timestamp(Fixtures.date(minutes: 1))) }
        let plan = try Plan(origin: origin, attendees: Attendees(people), activity: Fixtures.boba, time: Fixtures.tonight)
        try root.apply(.proposalReady(SkillProposal(revision: 1, participants: people, terms: try Terms([.activity: .keywords([Fixtures.boba])]),
                                                    plan: plan)), at: Timestamp(Fixtures.date(minutes: 2)))
        try root.apply(.ownerAccepted(revision: 1), at: Timestamp(Fixtures.date(minutes: 3)))
        try root.apply(.everyoneConfirmed(revision: 1), at: Timestamp(Fixtures.date(minutes: 4)))
        root.record(.plan(plan))
        return root
    }

    func phone(_ person: PeerID) -> Phone { network.phones[person]! }

    /// Starts `change` from `person`'s plan detail, as lane A's coordinator
    /// does: the chain planner's start, save, apply .started, then the service.
    @discardableResult
    func suggest(_ change: PlanChange, by person: PeerID, cards: [PeerID: AgentCard]? = nil, expiresIn minutes: Int = 30) async throws -> Interaction {
        let phone = phone(person)
        let planner = ChainPlanner(registry: Fixtures.registry, me: person)
        let all = await phone.all()
        let root = try #require(all.first { $0.plan?.origin == origin && $0.state == .planned })
        let plan = try #require(root.plan)
        let tap = OwnerTap(at: Timestamp(clock.now))
        let expiry = Timestamp(clock.now.addingTimeInterval(Double(minutes) * 60))
        let start: ChainStart
        if change == .leave {
            let (rules, _) = try change.encoded(for: plan)
            start = try planner.beginLeave(from: root.id, in: all, settings: Fixtures.settings, tap: tap, rules: rules, expiresAt: expiry)
        } else {
            let everyone = cards ?? Dictionary(uniqueKeysWithValues: (network.phones.keys.filter { $0 != person }).map { ($0, Fixtures.card()) })
            let row = try #require(planner.changeOffer(for: root.id, in: all, settings: Fixtures.settings, cards: everyone, now: clock.now))
            let (rules, inputs) = try change.encoded(for: plan)
            start = try planner.beginChange(row, in: all, settings: Fixtures.settings, cards: everyone, now: clock.now, tap: tap,
                                            consent: row.consent(approvedAt: tap.at), rules: rules, extraInputs: inputs, expiresAt: expiry)
        }
        var link = start.interaction
        try link.apply(.started, at: tap.at)
        try await phone.store.save(link)
        try await phone.service.start(start.request)
        return link
    }

    /// The open card `person` has for a suggestion, if any. Records nothing,
    /// so it can be polled.
    func openCard(of person: PeerID) async -> Interaction? {
        await phone(person).changes().first { $0.role == .invitee && $0.state == .proposed }
    }

    /// The one open card `person` has for a suggestion.
    func card(of person: PeerID) async throws -> Interaction {
        try #require(await openCard(of: person))
    }
}
