import Foundation
import SimulatorKit
import StarlingChaining
import StarlingChangePlan
import StarlingCore
import StarlingFakes
import StarlingPolicy
import Synchronization
import Testing

/// Loss occurs after the secure channel and sole Inbox accepted the message,
/// before service delivery. The original authenticated envelope is retained.
actor ChangeRelay: AgentBehavior {
    var service: ChangePlanService?
    private(set) var handled: Set<MessageID> = []
    private(set) var lost: [Envelope] = []
    private var drops: [MessageBody.Kind: Int] = [:]
    private var droppingConfirmations = 0
    func attach(_ service: ChangePlanService?) { self.service = service }
    func drop(_ kind: MessageBody.Kind, count: Int = 1) { drops[kind, default: 0] += count }
    func dropConfirmations(_ count: Int = 1) { droppingConfirmations += count }
    func respond(to envelope: Envelope, in agent: SimulatedAgent) async {
        if case .accept(let acceptance) = envelope.body, acceptance.terms.values.isEmpty, droppingConfirmations > 0 {
            droppingConfirmations -= 1
            lost.append(envelope)
        } else if drops[envelope.body.kind, default: 0] > 0 {
            drops[envelope.body.kind, default: 0] -= 1
            lost.append(envelope)
        } else {
            await service?.handle(.message(envelope))
        }
        handled.insert(envelope.id)
    }
    /// Repeated delivery at the service boundary, retaining authenticated identity.
    func repeatDelivery(_ envelope: Envelope) async { await service?.handle(.message(envelope)) }
}

/// Absolute injected deadlines cannot be missed by registering a sleep late.
final class ChangeClock: Sendable {
    private struct State {
        var now = P15.date
        var sleepers: [UUID: (Date, CheckedContinuation<Void, any Error>)] = [:]
        var cancelled: Set<UUID> = []
    }
    private let state = Mutex(State())
    var now: Date { state.withLock { $0.now } }
    var deadlines: [Date] { state.withLock { $0.sleepers.values.map(\.0).sorted() } }
    func sleep(until date: Date) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = state.withLock {
                    if $0.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if $0.now >= date { return .success(()) }
                    $0.sleepers[id] = (date, continuation)
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let waiting = self.state.withLock {
                let waiting = $0.sleepers.removeValue(forKey: id)
                if waiting == nil { $0.cancelled.insert(id) }
                return waiting
            }
            waiting?.1.resume(throwing: CancellationError())
        }
    }
    func advance(to date: Date) {
        let due = state.withLock {
            precondition(date >= $0.now)
            $0.now = date
            let due = $0.sleepers.filter { $0.value.0 <= date }
            for id in due.keys { $0.sleepers[id] = nil }
            return due.values.map(\.1)
        }
        for waiter in due { waiter.resume() }
    }
}

final class ChangePhone: Sendable {
    let agent: SimulatedAgent
    let relay: ChangeRelay
    let clock: ChangeClock
    let events = PlaceEvents(skill: ChangePlan.descriptor.ref)
    let ledger = PlaceConversationLedger()
    let journal: any ChangePlanJournal
    let observer = RecordingOutboxObserver()
    let consent: any ConsentProvider
    let peers = InMemoryPairedPeerStore()
    let outbox: Outbox
    let policy: any PolicyEngine
    private let current = Mutex<ChangePlanService?>(nil)
    private let consumers = Mutex<[Task<Void, Never>]>([])
    var service: ChangePlanService { current.withLock { $0! } }
    var id: PeerID { agent.id }

    init(agent: SimulatedAgent, relay: ChangeRelay, clock: ChangeClock,
         choices: [PrivacyTopic: SharingChoice], consent: any ConsentProvider = ScriptedConsentProvider(.approved),
         observer: (any OutboxObserver)? = nil, journal: any ChangePlanJournal = InMemoryChangePlanJournal()) throws {
        self.journal = journal
        self.agent = agent; self.relay = relay; self.clock = clock; self.consent = consent
        policy = DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty,
            disclosure: try PrivacySettings(choices).disclosureRules), pairedPeers: peers)
        let recorder = self.observer
        outbox = Outbox(transport: try #require(agent.secureTransport), policy: policy, consent: consent,
            observer: observer.map { ChangeObservers(record: recorder, extra: $0) as any OutboxObserver } ?? recorder, sequences: InMemorySentSequenceStore(), ledger: ledger,
            now: { clock.now })
    }
    func boot(restore: Bool = false) async throws {
        let store = events.store
        let fresh = ChangePlanService(outbox: outbox, ledger: ledger, journal: journal, me: id, planLookup: { origin in
            guard let root = try? await store.all().first(where: { $0.state == .planned && $0.plan?.origin == origin }),
                  let plan = root.plan else { return nil }
            return PlanRef(interaction: root.id, plan: plan)
        }, now: { self.clock.now }, sleep: { try await self.clock.sleep(until: $0) })
        current.withLock { $0 = fresh }
        let events = events
        consumers.withLock { $0.append(Task { for await event in fresh.events { await events.record(event) } }) }
        for hello in await agent.received where hello.body.kind == .hello { await fresh.handle(.message(hello)) }
        if restore { await fresh.restore(try await events.store.all()) }
        await relay.attach(fresh)
    }
    func restart() async throws {
        await relay.attach(nil)
        await service.shutdown()
        for task in consumers.withLock({ $0 }) { await task.value }
        try await boot(restore: true)
    }
    func stop() async {
        await ledger.release()
        await relay.attach(nil)
        await service.shutdown()
        for task in consumers.withLock({ $0 }) { await task.value }
    }
    func all() async throws -> [Interaction] { try await events.store.all() }
    func root(_ origin: ConversationID) async throws -> Interaction {
        try #require(try await all().first { $0.plan?.origin == origin })
    }
    func plan(_ origin: ConversationID) async throws -> Plan { try #require(try await root(origin).plan) }
    func wait(_ state: InteractionState, _ conversation: ConversationID) async throws -> Interaction {
        try await P15.eventually("Change the plan reaches \(state)") {
            try await self.events.interaction(conversation)?.state == state
        }
        return try #require(try await events.interaction(conversation))
    }
    func waitRevision(_ revision: UInt32, origin: ConversationID) async throws {
        try await P15.eventually("plan artifact reaches revision \(revision)") {
            try await self.plan(origin).revision == revision
        }
    }
    func accept(_ conversation: ConversationID) async throws {
        let card = try await wait(.proposed, conversation)
        try await service.answer(card.id, with: .accept(proposal: #require(card.proposalRevision)))
    }
    func sent(_ conversation: ConversationID? = nil) async -> [Envelope] {
        await observer.records.map(\.envelope).filter { conversation == nil || $0.conversation == conversation }
    }
    @discardableResult
    func send(_ body: MessageBody, to other: ChangePhone, conversation: ConversationID = ConversationID(),
              parent: ConversationID, skill: SkillRef = ChangePlan.descriptor.ref, mode: SendMode = .invite,
              context: OutboundContext = .empty) async throws -> Envelope {
        let envelope = try await outbox.send(body, to: other.id, conversation: conversation,
            recipientCard: P15.card([ChangePlan.descriptor.ref]), context: context,
            skill: skill, mode: mode, chainedFrom: parent)
        try await P15.eventually("authenticated change input handled") { await other.relay.handled.contains(envelope.id) }
        return envelope
    }
}

struct ChangeWorld: Sendable {
    let simulation: Simulation
    let phones: [ChangePhone]
    let origin: ConversationID
    let clock: ChangeClock
    static let registry = try! SkillRegistry(SampleSkills.all + [ChangePlan.descriptor])
    static let settings = SkillSettings(flags: SkillFlags(P15.allFlags.enabled.union([.changePlan])))
    static let changedActivity = try! Keyword("dinner")
    static let change = PlanChange.change(time: nil, activity: changedActivity, adding: nil)
    static let terms = try! Terms([.activity: .keywords([changedActivity])])

    static func make(members: Int = 3, extras: Int = 1,
                     choices: [PrivacyTopic: SharingChoice] = [.people: .share, .place: .share],
                     inviteesNever: Bool = false, firstConsent: (any ConsentProvider)? = nil,
                     firstObserver: (any OutboxObserver)? = nil, firstJournal: (any ChangePlanJournal)? = nil) async throws -> Self {
        let clock = ChangeClock()
        let simulation = Simulation(now: { clock.now }, security: .secureChannel)
        var phones: [ChangePhone] = []
        for index in 0..<(members + extras) {
            let relay = ChangeRelay()
            let agent = try await simulation.addAgent("Plan friend \(index)", behavior: relay)
            phones.append(try ChangePhone(agent: agent, relay: relay, clock: clock,
                choices: index > 0 && inviteesNever ? [.people: .never, .place: .never] : choices,
                consent: index == 0 ? firstConsent ?? ScriptedConsentProvider(.approved) : ScriptedConsentProvider(.approved),
                observer: index == 0 ? firstObserver : nil,
                journal: index == 0 ? firstJournal ?? InMemoryChangePlanJournal() : InMemoryChangePlanJournal()))
        }
        try await P15.waitForMesh(simulation)
        for phone in phones {
            let secure = try #require(phone.agent.secureTransport)
            for other in phones where other.id != phone.id {
                let key = try #require(await secure.status(of: other.id).provenKey)
                try await phone.peers.save(PairedPeer(publicKey: key, nickname: other.agent.name, pairedAt: P15.now))
            }
        }
        for phone in phones {
            for other in phones where phone.id != other.id {
                let hello = try await phone.outbox.send(.hello(P15.card([ChangePlan.descriptor.ref])),
                    to: other.id, conversation: ConversationID())
                try await P15.eventually("change capability reaches paired peer") { await other.agent.received.contains(hello) }
            }
        }
        let origin = ConversationID()
        let roster = Array(phones.prefix(members).map(\.id))
        for phone in phones.prefix(members) {
            try await phone.events.add(root(origin: origin, roster: roster, me: phone.id))
        }
        for phone in phones { try await phone.boot() }
        return Self(simulation: simulation, phones: phones, origin: origin, clock: clock)
    }
    /// Separate local Plan IDs model independent stores. PC28 additionally
    /// forms parents through the real skills instead of these seeded roots.
    static func root(origin: ConversationID, roster: [PeerID], me: PeerID, revision: UInt32 = 0) throws -> Interaction {
        var root = Interaction(conversation: origin, skill: SampleSkills.downFor.ref,
            role: me == roster[0] ? .initiator : .invitee,
            participants: roster.filter { $0 != me }, createdAt: P15.now)
        if root.role == .initiator { try root.apply(.started, at: P15.now) }
        let plan = try Plan(origin: origin, attendees: Attendees(roster), activity: Keyword("boba"), time: P15.slot, revision: revision)
        try root.apply(.proposalReady(SkillProposal(revision: 1, participants: roster,
            terms: Terms([.activity: .keywords([try Keyword("boba")])]), plan: plan)), at: P15.now)
        try root.apply(.ownerAccepted(revision: 1), at: P15.now)
        try root.apply(.everyoneConfirmed(revision: 1), at: P15.now)
        root.record(.plan(plan))
        return root
    }
    func prepare(_ change: PlanChange = Self.change, by index: Int = 0,
                 cards: [PeerID: AgentCard]? = nil) async throws -> ChainStart {
        let phone = phones[index]
        let all = try await phone.all()
        let root = try await phone.root(origin)
        let planner = ChainPlanner(registry: Self.registry, me: phone.id)
        let tap = OwnerTap(at: Timestamp(clock.now))
        let expiry = Timestamp(clock.now.addingTimeInterval(300))
        let encoded = try change.encoded(for: #require(root.plan))
        if change == .leave {
            return try planner.beginLeave(from: root.id, in: all, settings: Self.settings,
                tap: tap, rules: encoded.rules, expiresAt: expiry)
        }
        let cards = try cards ?? Dictionary(uniqueKeysWithValues: phones.filter { $0.id != phone.id }.map {
            ($0.id, try P15.card([ChangePlan.descriptor.ref]))
        })
        let row = try #require(planner.changeOffer(for: root.id, in: all, settings: Self.settings, cards: cards, now: clock.now))
        return try planner.beginChange(row, in: all, settings: Self.settings, cards: cards,
            now: clock.now, tap: tap, consent: row.consent(approvedAt: tap.at),
            rules: encoded.rules, extraInputs: encoded.inputs, expiresAt: expiry)
    }
    @discardableResult
    func start(_ change: PlanChange = Self.change, by index: Int = 0) async throws -> Interaction {
        let start = try await prepare(change, by: index)
        try await launch(start, by: index)
        return start.interaction
    }
    func launch(_ start: ChainStart, by index: Int = 0) async throws {
        var interaction = start.interaction
        try interaction.apply(.started, at: Timestamp(clock.now))
        try await phones[index].events.add(interaction)
        try await phones[index].service.start(start.request)
    }
    func received(_ envelope: Envelope, by index: Int) async throws {
        try await P15.eventually("real change service handles message") { await phones[index].relay.handled.contains(envelope.id) }
    }
    func proposal(by index: Int = 0, round: UInt16 = 0, terms: Terms = Self.terms,
                  parent: ConversationID? = nil) async throws -> Proposal {
        let plan = try await phones[index].plan(origin)
        return try Proposal(round: round, terms: terms,
            inReplyTo: ChangePlanService.rosterDigest(origin: parent ?? origin, revision: UInt32(round),
                suggester: phones[index].id, asked: plan.attendees.peers.filter { $0 != phones[index].id }),
            expiresAt: Timestamp(clock.now.addingTimeInterval(300)))
    }
    func offers(_ conversation: ConversationID) async -> [Envelope] {
        await phones[0].sent(conversation).filter { $0.body.kind == .propose }
    }
    func stop() async {
        for phone in phones { await phone.stop() }
        await simulation.stop()
    }
    func checkHealthy() async {
        for phone in phones { #expect(await phone.events.invalid.isEmpty) }
    }
}

struct ChangeObservers: OutboxObserver {
    let record: RecordingOutboxObserver
    let extra: any OutboxObserver
    func outbox(willSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async throws {
        try await record.outbox(willSend: envelope, context: context, decision: decision, disclosed: disclosed)
        try await extra.outbox(willSend: envelope, context: context, decision: decision, disclosed: disclosed)
    }
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {}
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async {
        await record.outbox(didSend: envelope, context: context, decision: decision, disclosed: disclosed)
        await extra.outbox(didSend: envelope, context: context, decision: decision, disclosed: disclosed)
    }
}

actor ChangeSendGate: OutboxObserver {
    private var held = true
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    func release() { held = false; waiter?.resume(); waiter = nil }
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {}
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async {
        guard held, envelope.body.kind == .propose else { return }
        waiting = true
        await withCheckedContinuation { waiter = $0 }
    }
}

actor ChangeFailingJournal: ChangePlanJournal {
    struct WriteFailed: Error {}
    let base = InMemoryChangePlanJournal()
    private(set) var attempts = 0
    func save(_ record: ChangePlanRecord) async throws { attempts += 1; throw WriteFailed() }
    func remove(_ key: UUID) async throws { try await base.remove(key) }
    func records() async throws -> [ChangePlanRecord] { try await base.records() }
}
