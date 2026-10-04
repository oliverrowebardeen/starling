import DownFor
import Foundation
import SimulatorKit
import StarlingCore
import StarlingFakes
import StarlingNegotiation
import StarlingPolicy
import Synchronization
import Testing

actor DownModelProbe {
    private(set) var matches: [([Keyword], [Keyword])] = []
    private(set) var interpretations = 0
    private(set) var decisions = 0
    var invented: Keyword?
    func invent(_ keyword: Keyword) { invented = keyword }
    func match(_ wanted: [Keyword], _ offered: [Keyword]) -> [KeywordMatch] {
        matches.append((wanted, offered))
        if let invented { return wanted.map { KeywordMatch(wanted: $0, offered: invented, strength: .equivalent) } }
        return ScriptedAgentModel.exactMatches(wanted: wanted, offered: offered)
    }
    func interpret() { interpretations += 1 }
    func decide() { decisions += 1 }
    nonisolated var model: ScriptedAgentModel {
        ScriptedAgentModel(onInterpret: { _, _ in await self.interpret(); throw AgentModelError.unsupported },
            onMatch: { await self.match($0, $1) },
            onDecide: { _ in await self.decide(); throw AgentModelError.unsupported })
    }
}

actor DownConsent: ConsentProvider {
    private(set) var requests: [Disclosure] = []
    private var held: Set<PeerID> = []
    private var waiters: [CheckedContinuation<ConsentOutcome, Never>] = []
    func hold(_ peer: PeerID) { held.insert(peer) }
    func release() { held = []; for waiter in waiters { waiter.resume(returning: .approved) }; waiters = [] }
    func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        requests.append(disclosure)
        guard held.contains(disclosure.recipient) else { return .approved }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

actor DownBoundaryPolicy: PolicyEngine {
    let base: any PolicyEngine
    private var denyAcceptance = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var waiting = false
    private(set) var finished = false
    init(_ base: any PolicyEngine) { self.base = base }
    func holdAcceptanceDenial() { denyAcceptance = true }
    func release() { waiter?.resume(); waiter = nil }
    func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        if denyAcceptance && message.envelope.body.kind == .accept {
            waiting = true
            await withCheckedContinuation { waiter = $0 }
            finished = true
            return .deny(PolicyViolation(rule: "test.current-acceptance", issue: .activity))
        }
        return await base.evaluate(message)
    }
    func disclosedItems(for message: OutboundMessage) async throws -> [DisclosedItem] { try await base.disclosedItems(for: message) }
}

actor DownWire: OutboxObserver {
    struct Record: Sendable {
        let envelope: Envelope
        let context: OutboundContext
        let items: [DisclosedItem]?
        let at: SuspendingClock.Instant
    }
    private(set) var records: [Record] = []
    private var proposalCount = 0
    private var heldProposal: Int?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var holding = false
    func holdProposal(_ number: Int) { heldProposal = number }
    func release() { heldProposal = nil; holding = false; waiter?.resume(); waiter = nil }
    func outbox(willSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async throws {
        guard envelope.body.kind == .propose else { return }
        proposalCount += 1
        if proposalCount == heldProposal {
            holding = true
            await withCheckedContinuation { waiter = $0 }
        }
    }
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) {}
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) {
        records.append(Record(envelope: envelope, context: context, items: disclosed, at: SuspendingClock.now))
    }
}

/// Actual Down for service over the existing authenticated channel and sole
/// Inbox relay. Lifecycle application is a fixture, not the app coordinator.
final class DownPhone: Sendable {
    let phone: PlacePhone
    let events = PlaceEvents(skill: DownFor.ref)
    let model = DownModelProbe()
    let consent = DownConsent()
    let wire = DownWire()
    let store = InMemoryDownForRequestStore()
    let policy: DownBoundaryPolicy
    let outbox: Outbox
    let configuration: DownForConfiguration
    private let current = Mutex<DownForService?>(nil)
    private let tasks = Mutex<[Task<Void, Never>]>([])
    var id: PeerID { phone.id }
    var service: DownForService { current.withLock { $0! } }
    static let configuration = DownForConfiguration(retryInterval: .milliseconds(150), maxAttempts: 20,
        ownerWindow: .seconds(3), maxBackoff: .milliseconds(300))
    static let transcriptConfiguration = DownForConfiguration(retryInterval: .milliseconds(150), maxAttempts: 20,
        ownerWindow: .milliseconds(1250), maxBackoff: .milliseconds(300))
    static let slot = try! TimeSlot(start: P15.date.addingTimeInterval(3600), end: P15.date.addingTimeInterval(10800))
    static let expiry = Timestamp(P15.date.addingTimeInterval(14400))

    init(_ phone: PlacePhone, configuration: DownForConfiguration, choices: [PrivacyTopic: SharingChoice]) throws {
        self.phone = phone; self.configuration = configuration
        policy = DownBoundaryPolicy(DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty,
            disclosure: try PrivacySettings(choices).disclosureRules), pairedPeers: phone.peers))
        outbox = Outbox(transport: try #require(phone.agent.secureTransport),
            policy: policy,
            consent: consent, observer: wire, ledger: phone.conversations, now: { P15.date })
    }
    func boot(restoring: [Interaction]? = nil) async throws {
        let clock = phone.clock
        let fresh = DownForService(localPeer: id, outbox: outbox, model: model.model, psi: InsecurePSIStub(),
            ledger: phone.conversations, store: store, pairedPeers: phone.peers,
            clock: SkillClock(now: clock.clock.now, sleep: clock.clock.sleep),
            timeZone: TimeZone(secondsFromGMT: 0)!, configuration: configuration)
        current.withLock { $0 = fresh }
        let events = events
        tasks.withLock { $0.append(Task { for await event in fresh.events { await events.record(event) } }) }
        for envelope in await phone.agent.received where envelope.body.kind == .hello { await fresh.handle(.message(envelope)) }
        for peer in try await phone.peers.all() { await fresh.handle(.peerAvailable(peer.id)) }
        await phone.relay.attach(fresh)
        if let restoring { await fresh.restore(restoring) }
    }
    func restart() async throws {
        let saved = try await events.store.all()
        await phone.relay.attach(nil)
        await service.shutdown()
        try await boot(restoring: saved)
    }
    func stop() async {
        await consent.release()
        await policy.release()
        await wire.release()
        await service.shutdown()
        for task in tasks.withLock({ $0 }) { task.cancel() }
    }
    static func rules(_ activities: [String] = ["boba"], avoided: [String] = [], privateChips: Bool = false) throws -> OwnerRules {
        var limits: [IssueKey: [Constraint]] = [
            .activity: [try Constraint(.prefers(liked: activities.map { try Keyword($0) }, avoided: avoided.map { try Keyword($0) }), strength: .soft)],
            .time: [try Constraint(.within([slot]))],
        ]
        if privateChips {
            limits[.budget] = [try Constraint(.atMost(MoneyAmount(minorUnits: 731)))]
            limits[.place] = [try Constraint(.prefers(liked: [Keyword("private cove")], avoided: []), strength: .soft)]
        }
        return try OwnerRules(constraints: ConstraintSet(limits))
    }
    func start(with participants: [PeerID], mode: SendMode = .askQuietly, rules: OwnerRules? = nil,
               inputs: [Artifact] = [], parent: ConversationID? = nil) async throws -> Interaction {
        var interaction = Interaction(skill: DownFor.ref, role: .initiator, participants: participants, createdAt: P15.now)
        try interaction.apply(.started, at: P15.now)
        try await events.add(interaction)
        let intent = SkillIntent(skill: DownFor.ref, rules: try rules ?? Self.rules(), audience: .picked(participants), mode: mode, expiresAt: Self.expiry)
        try await service.start(SkillRequest(interaction: interaction.id, conversation: interaction.conversation,
            intent: intent, participants: participants, inputs: inputs, chainedFrom: parent))
        return interaction
    }
    func wait(_ state: InteractionState, _ interaction: Interaction) async throws -> Interaction {
        try await P15.eventually("Down for reaches \(state)") {
            (try? await self.events.store.interaction(interaction.id)?.state) == state
        }
        return try #require(await events.store.interaction(interaction.id))
    }
    func accept(_ interaction: Interaction) async throws {
        let card = try await wait(.proposed, interaction)
        try await service.answer(card.id, with: .accept(proposal: #require(card.proposalRevision)))
    }
    func sent(_ conversation: ConversationID) async -> [Envelope] { await wire.records.map(\.envelope).filter { $0.conversation == conversation } }
    @discardableResult
    func send(_ body: MessageBody, to peer: PeerID, in conversation: ConversationID,
              mode: SendMode = .askQuietly, skill: SkillRef? = DownFor.ref, parent: ConversationID? = nil,
              context: OutboundContext = .empty) async throws -> Envelope {
        try await outbox.send(body, to: peer, conversation: conversation, recipientCard: P15.card([DownFor.ref]),
            context: context, skill: skill, mode: skill == nil ? nil : mode, chainedFrom: parent)
    }
    func openPSI(to peer: PeerID, conversation: ConversationID = ConversationID()) async throws -> (Envelope, PSIFrame) {
        let tokens = SlotTokenSet(namespace: "down_for/v1", constraints: try Self.rules().constraints,
            now: P15.date, expiresAt: Self.expiry.date, timeZone: TimeZone(secondsFromGMT: 0)!)
        let psi = InsecurePSIStub()
        let session = try psi.makeSession(role: .initiator, localSet: tokens.elements, configuration: SlotTokenSet.psiConfiguration())
        guard case .send(let payload) = try await session.start() else { throw ValidationError("test", "no PSI step") }
        let frame = try PSIFrame(session: UUID(), step: 0, payload: payload)
        let context = OutboundContext(psi: .init(provider: psi.descriptor, inputs: [.time: .slots(tokens.slots)]))
        return (try await send(.psi(frame), to: peer, in: conversation, context: context), frame)
    }
}

struct DownWorld: Sendable {
    let base: PlaceWorld
    let phones: [DownPhone]
    static func make(_ count: Int = 3, configuration: DownForConfiguration = DownPhone.configuration,
                     choices: [PrivacyTopic: SharingChoice] = [:], inviteesNever: Bool = false) async throws -> Self {
        let base = try await PlaceWorld.make(count: count)
        let phones = try base.phones.sorted { $0.id < $1.id }.enumerated().map { index, phone in
            let privateChoices = Dictionary(uniqueKeysWithValues: PrivacyTopic.allCases.filter { $0 != .time && $0 != .activity }.map { ($0, SharingChoice.never) })
            return try DownPhone(phone, configuration: configuration, choices: inviteesNever && index > 0 ? privateChoices : choices)
        }
        for phone in phones {
            for other in phones where phone.id != other.id {
                let hello = try await phone.outbox.send(.hello(P15.card([DownFor.ref])), to: other.id, conversation: ConversationID())
                try await P15.eventually("authenticated Down for card") { await other.phone.agent.received.contains(hello) }
            }
        }
        for phone in phones { try await phone.boot() }
        return Self(base: base, phones: phones)
    }
    func stop() async { for phone in phones { await phone.stop() }; await base.stop() }
    func delivered(_ envelope: Envelope, to phone: DownPhone) async throws {
        try await base.delivered(envelope, to: phone.phone)
        let sender = try #require(phones.first { $0.id == envelope.sender })
        try await settle(from: sender, to: phone)
    }
    /// Down for queues each friend's work. A retired-conversation sentinel
    /// reaches its ledger only after earlier work on that queue completes.
    /// It travels through the real Outbox/Inbox and cannot open a request.
    func settle(from sender: DownPhone, to phone: DownPhone) async throws {
        let marker = ConversationID()
        try await phone.outbox.retire(marker)
        let sent = try await sender.send(.reject(Rejection(proposal: MessageID(), reason: .noOverlap)),
                                         to: phone.id, in: marker)
        try await base.delivered(sent, to: phone.phone)
        try await P15.eventually("Down for drains the friend's preceding work") {
            await phone.phone.conversations.checked.contains(marker)
        }
    }
    func pair(_ a: DownPhone, _ b: DownPhone, rules: OwnerRules? = nil) async throws -> (Interaction, Interaction) {
        let aRequest = try await a.start(with: [b.id], rules: rules)
        let bRequest = try await b.start(with: [a.id], rules: rules)
        _ = try await a.wait(.proposed, aRequest)
        _ = try await b.wait(.proposed, bRequest)
        return (aRequest, bRequest)
    }
}
