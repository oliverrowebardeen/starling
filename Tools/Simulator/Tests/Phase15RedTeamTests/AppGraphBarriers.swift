import StarlingChaining
import StarlingCore
import StarlingFeatures

/// Observes completion in the real services, after AppModel updates its UI
/// card cache. Seeing a card on screen alone is not an ingress barrier.
actor AppSkillDelivery {
    private var handled: [MessageID: Set<SkillID>] = [:]
    private var heldHello: PeerID?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var holding = false

    func holdHello(from peer: PeerID) { heldHello = peer }
    func release() { heldHello = nil; holding = false; waiter?.resume(); waiter = nil }
    func before(_ event: InboxEvent, skill: SkillID) async {
        guard skill == .downFor, case .message(let envelope) = event,
              case .hello = envelope.body, envelope.sender == heldHello else { return }
        holding = true
        await withCheckedContinuation { waiter = $0 }
    }
    func after(_ event: InboxEvent, skill: SkillID) {
        guard case .message(let envelope) = event, case .hello = envelope.body else { return }
        handled[envelope.id, default: []].insert(skill)
    }
    func finished(_ message: MessageID, skills: Set<SkillID>) -> Bool {
        skills.isSubset(of: handled[message, default: []])
    }
}

struct AppObservedSkill: SkillService {
    let base: any SkillService
    let delivery: AppSkillDelivery
    var descriptor: SkillDescriptor { base.descriptor }
    var events: AsyncStream<SkillEvent> { base.events }
    func start(_ request: SkillRequest) async throws { try await base.start(request) }
    func answer(_ interaction: InteractionID, with answer: OwnerAnswer) async throws { try await base.answer(interaction, with: answer) }
    func withdraw(_ interaction: InteractionID) async { await base.withdraw(interaction) }
    func restore(_ interactions: [Interaction]) async { await base.restore(interactions) }
    func shutdown() async { await base.shutdown() }
    func handle(_ event: InboxEvent) async {
        guard case .message(let envelope) = event, case .hello = envelope.body else {
            await base.handle(event)
            return
        }
        await delivery.before(event, skill: descriptor.id)
        await base.handle(event)
        await delivery.after(event, skill: descriptor.id)
    }
}

/// The fixture replaces app graphs without killing the process or radio.
/// Close file admission and drain admitted operations before simulating disk
/// damage. An old graph's cached journal must not repair the damaged fixture.
actor AppJournalLifetime: EgressJournal {
    struct Closed: Error {}
    let base: FileEgressJournal
    private var active = 0
    private(set) var closed = false
    private var drain: [CheckedContinuation<Void, Never>] = []
    private var heldConversation: ConversationID?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var holding = false

    init(file: JSONFile) { base = FileEgressJournal(file: file) }
    func holdWrite(in conversation: ConversationID) { heldConversation = conversation }
    func release() { heldConversation = nil; holding = false; waiter?.resume(); waiter = nil }
    private func enter() throws {
        guard !closed else { throw Closed() }
        active += 1
    }
    private func leave() {
        active -= 1
        if active == 0 { for waiter in drain { waiter.resume() }; drain = [] }
    }
    func closeAndDrain() async {
        closed = true
        if active > 0 { await withCheckedContinuation { drain.append($0) } }
    }
    func remember(_ entry: EgressJournalEntry) async throws {
        try enter()
        defer { leave() }
        if entry.conversation == heldConversation {
            holding = true
            await withCheckedContinuation { waiter = $0 }
        }
        try await base.remember(entry)
    }
    func forget(_ message: MessageID) async throws {
        try enter()
        defer { leave() }
        try await base.forget(message)
    }
    func unresolved() async throws -> [EgressJournalEntry] {
        try enter()
        defer { leave() }
        return try await base.unresolved()
    }
}
