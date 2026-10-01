import Foundation
import StarlingCore
import StarlingNegotiation

/// The Down for... skill's runtime (ADR 0210), over the app's one Outbox and
/// Inbox.
///
/// Each owner request is one initiator `Interaction`. Its starter is the
/// hub of a group: a PSI run with each friend over free half-hours; details
/// (activity, budget) only with friends whose time overlaps; then one plan
/// built from everyone's private answers, with the roster in it. Each
/// friend's agent answers only while its own owner has an open Down for...
/// request that includes the starter, so one-sided interest is never shown
/// to anyone. When two open requests reach each other, the one started by
/// the lower `PeerID` carries the pair, and a friend joins at most one group.
/// The proposal appears on each member's own request as a card; nobody is
/// in a plan until everyone in it said "I'm in".
///
/// Every send goes through the Outbox with `DownFor.ref`; the app passes
/// every `InboxEvent` to `handle(_:)`.
public actor DownForService: SkillService {
    public nonisolated let descriptor = DownFor.descriptor
    public nonisolated let events: AsyncStream<SkillEvent>
    let continuation: AsyncStream<SkillEvent>.Continuation

    let localPeer: PeerID
    let outbox: Outbox
    let model: any AgentModel
    let psi: any PSIProvider
    let store: any DownForRequestStore
    let clock: SkillClock
    let timeZone: TimeZone
    let configuration: DownForConfiguration

    // MARK: State

    enum Engagement: Hashable, Sendable {
        /// The request runs its own group.
        case hub
        /// The request answers another starter's group, in that run.
        case member(RunKey)
    }

    /// The hub's current proposal.
    struct Group: Sendable {
        var revision: UInt32
        var terms: Terms
        var members: [PeerID]
        var ownerAccepted = false
        /// Members whose confirmation is still on its way; nil until
        /// everyone said "I'm in".
        var confirming: Set<PeerID>?
        var window: Task<Void, Never>?
    }

    struct Request: Sendable {
        let record: DownForRequestRecord
        let profile: DownForProfile
        /// A local copy of the lifecycle, so the service only reports events
        /// the state machine accepts.
        var mirror: Interaction
        var engagement = Engagement.hub
        var group: Group?
        var runs: [PeerID: Int] = [:]
        /// Friends this request is done with: no overlap, a refusal, a pass.
        var settled: Set<PeerID> = []
        var unsupported: Set<PeerID> = []
        /// Disclosures the owner approved in this request, so a retry of the
        /// same send does not suspend the interaction again.
        var approved: Set<Disclosure> = []
        var openConsents: [UInt32: Disclosure] = [:]
        var timer: Task<Void, Never>?
        /// When this phone took the request on, for the quiet period
        /// before the starter proposes.
        var since = ContinuousClock.now
        var quiet: Task<Void, Never>?

        var id: InteractionID { record.interaction }
        var conversation: ConversationID { record.conversation }

        /// Still gathering friends: negotiating, possibly behind a consent sheet.
        var isGathering: Bool {
            switch mirror.state {
            case .negotiating, .awaitingConsent(resume: .negotiating): true
            default: false
            }
        }
    }

    var requests: [InteractionID: Request] = [:]
    var runs: [RunKey: Run] = [:]
    var finished: [RunKey: Finished] = [:]
    var finishedOrder: [RunKey] = []
    var reachable: Set<PeerID> = []
    var cards: [PeerID: AgentCard] = [:]

    var workers: [PeerID: (queue: AsyncStream<Work>.Continuation, task: Task<Void, Never>)] = [:]
    var queued: [PeerID: Int] = [:]
    var timers: [RunKey: Task<Void, Never>] = [:]
    var pendingWork: [UUID: PendingWork] = [:]

    /// A send or model call in flight, tracked by run and by request, so
    /// ending either cancels it: nothing suspended on a consent sheet or the
    /// policy re-check leaves after a run ends or a request is withdrawn.
    struct PendingWork {
        let run: RunKey?
        let request: InteractionID?
        let task: Task<Void, Never>
        let abandon: @Sendable () -> Void
    }

    /// For tests and logs. Never shown to the owner or sent.
    struct Diagnostics: Sendable {
        var outcomes: [RunOutcome: Int] = [:]
        var modelCalls = 0
        /// Outbound values the final gate refused. Anything above zero is a
        /// bug upstream, caught before it reached the Outbox.
        var gateRefusals = 0
        var droppedWork = 0
        /// Events the local lifecycle copy refused to report.
        var refusedEvents = 0
    }

    var diagnostics = Diagnostics()

    /// - Parameters:
    ///   - localPeer: This phone's ID (the Outbox transport's `localPeer`),
    ///     which orders starters when two requests reach each other.
    ///   - outbox: The app's Outbox. Its consent provider should be wrapped
    ///     with `consentRelay(wrapping:)` so consent shows on the lifecycle.
    ///   - model: Used for one job: matching a starter's activities against
    ///     the owner's (ADR 0121).
    public init(
        localPeer: PeerID,
        outbox: Outbox,
        model: any AgentModel,
        psi: any PSIProvider,
        store: any DownForRequestStore = InMemoryDownForRequestStore(),
        clock: SkillClock = .system,
        timeZone: TimeZone = .current,
        configuration: DownForConfiguration = DownForConfiguration()
    ) {
        self.localPeer = localPeer
        self.outbox = outbox
        self.model = model
        self.psi = psi
        self.store = store
        self.clock = clock
        self.timeZone = timeZone
        self.configuration = configuration
        (events, continuation) = AsyncStream.makeStream(of: SkillEvent.self)
    }

    /// The PSI provider in use. While `isPrivate` is false, the consent
    /// sheet should say that finding shared time does not hide free times.
    public nonisolated var psiProvider: PSIProviderDescriptor { psi.descriptor }

    /// Which of `participants` cannot run Down for... with this phone, by
    /// their cards, so the app can say "Maya's Starling doesn't do this yet".
    /// A friend whose card has not arrived yet is not listed.
    public nonisolated static func unsupported(among participants: [PeerID], cards: [PeerID: AgentCard]) -> [PeerID: SkillSupport] {
        var result: [PeerID: SkillSupport] = [:]
        for peer in participants {
            if let support = cards[peer]?.support(for: DownFor.ref), !support.isSupported { result[peer] = support }
        }
        return result
    }

    // MARK: - SkillService

    public func start(_ request: SkillRequest) async throws {
        guard request.intent.skill.id == DownFor.ref.id, request.intent.skill.version.isCompatible(with: DownFor.ref.version) else {
            throw DownForError.wrongSkill
        }
        guard requests[request.interaction] == nil else { throw DownForError.alreadyStarted }
        let now = clock.now()
        guard request.intent.expiresAt.date > now else { throw DownForError.expired }
        let record = DownForRequestRecord(request)
        let profile = DownForProfile(rules: record.rules, inputs: record.inputs, expiresAt: record.expiresAt.date, timeZone: timeZone)
        guard !profile.liked.isEmpty else { throw DownForError.noActivity }
        guard !profile.tokens(now: now).slots.isEmpty else { throw DownForError.noAvailableTime }
        let participants = Self.unique(request.participants.filter { $0 != localPeer })
        guard !participants.isEmpty else { throw DownForError.noParticipants }

        // The coordinator applied `.started` when the owner sent the request
        // (ADR 0011, amendment 13); the local copy follows it without
        // reporting it again.
        var mirror = Interaction(
            id: request.interaction, conversation: request.conversation, skill: DownFor.ref, role: .initiator,
            participants: participants, createdAt: Timestamp(now)
        )
        try? mirror.apply(.started, at: Timestamp(now))
        var state = Request(record: record, profile: profile, mirror: mirror)
        state.unsupported = Set(Self.unsupported(among: participants, cards: cards).keys)
        requests[request.interaction] = state
        try? await store.save(record)

        guard requests[request.interaction] != nil else { return }
        if state.unsupported.count == participants.count {
            report(request.interaction, .unsupported)
            return
        }
        armExpiry(request.interaction)
        for peer in participants { enqueue(.start(request.interaction), for: peer) }
    }

    public func answer(_ interaction: InteractionID, with answer: OwnerAnswer) async throws {
        guard let request = requests[interaction] else { throw DownForError.unknownInteraction }
        switch answer {
        case .reply:
            throw DownForError.unsupportedAnswer
        case .pass:
            switch request.mirror.state {
            case .proposed, .awaitingConsent: break
            default: throw DownForError.notWaitingForOwner
            }
            // "If you pass, they just won't see it": the group carries on
            // without the owner, or ends for everyone the same way silence
            // would.
            guard endRequest(interaction, with: .ownerPassed, telling: .declinedByOwner) else { throw DownForError.notWaitingForOwner }
        case .accept(let revision):
            guard revision == request.mirror.proposalRevision else { throw DownForError.staleProposal(current: request.mirror.proposalRevision) }
            guard request.mirror.state == .proposed else { throw DownForError.notWaitingForOwner }
            guard report(interaction, .ownerAccepted(revision: revision)) else { throw DownForError.notWaitingForOwner }
            ownerAccepted(interaction)
        }
    }

    /// Ends the request and cancels every send still in flight for it,
    /// including one waiting on a consent sheet. Nothing more leaves for it;
    /// friends learn nothing beyond "no plan", when their own wait runs out.
    public func withdraw(_ interaction: InteractionID) async {
        endRequest(interaction, with: .withdrawn, telling: nil)
    }

    /// The request a conversation's sends belong to on this phone: its own
    /// conversation, or a run it answers in another starter's conversation
    /// with `peer`. For the app, to tie a consent sheet or an egress record
    /// to the right interaction.
    public func interaction(for conversation: ConversationID, peer: PeerID) -> InteractionID? {
        requests.values.first { $0.conversation == conversation }?.id ?? runs[RunKey(conversation: conversation, peer: peer)]?.request
    }

    /// Every event from the app's Inbox loop. Returns at once; work for each
    /// friend runs in order on its own task, so a consent sheet or a slow
    /// model call never holds up the loop.
    public func handle(_ event: InboxEvent) async {
        switch event {
        case .peerAvailable(let peer):
            reachable.insert(peer)
            for request in requests.values where request.record.participants.contains(peer) {
                enqueue(.start(request.id), for: peer)
            }
        case .peerUnavailable(let peer):
            reachable.remove(peer)
        case .message(let envelope):
            if case .hello(let card) = envelope.body {
                learn(card, from: envelope.sender)
            } else if let skill = envelope.skill, skill.id == DownFor.ref.id, skill.version.isCompatible(with: DownFor.ref.version) {
                enqueue(.message(envelope), for: envelope.sender)
            }
        case .dropped:
            break
        }
    }

    public func restore(_ interactions: [Interaction]) async {
        let now = clock.now()
        for interaction in interactions where interaction.skill.id == DownFor.ref.id && requests[interaction.id] == nil {
            switch interaction.state {
            case .planned:
                guard let record = try? await store.record(for: interaction.id) ?? Self.placeholder(for: interaction) else { continue }
                let profile = DownForProfile(rules: record.rules, inputs: record.inputs, expiresAt: record.expiresAt.date, timeZone: timeZone)
                requests[interaction.id] = Request(record: record, profile: profile, mirror: interaction)
                armPlanEnd(interaction.id)
            case .negotiating where interaction.role == .initiator:
                // Runs in flight died with the old process; their peers time
                // out. Start fresh ones under the same conversation.
                guard let record = try? await store.record(for: interaction.id), record.expiresAt.date > now else {
                    requests[interaction.id] = Self.orphan(interaction, timeZone: timeZone)
                    report(interaction.id, .failed)
                    continue
                }
                let profile = DownForProfile(rules: record.rules, inputs: record.inputs, expiresAt: record.expiresAt.date, timeZone: timeZone)
                requests[interaction.id] = Request(record: record, profile: profile, mirror: interaction)
                armExpiry(interaction.id)
                for peer in record.participants { enqueue(.start(interaction.id), for: peer) }
            case .done, .ended:
                continue
            default:
                // A consent sheet, a card, or a group in flight cannot be
                // rebuilt: the sheet is gone, and so is the starter's group.
                requests[interaction.id] = Self.orphan(interaction, timeZone: timeZone)
                report(interaction.id, .failed)
            }
        }
    }

    public func shutdown() async {
        // Records stay in the store, so `restore(_:)` can resume them.
        for id in Array(requests.keys) { discard(id, keepingRecord: true) }
        for key in Array(runs.keys) { end(key, .withdrawn) }
        cancelWork { _ in true }
        for worker in workers.values {
            worker.queue.finish()
            worker.task.cancel()
        }
        workers = [:]
        continuation.finish()
    }

    // MARK: - Reporting

    /// Applies `event` to the local copy and, if the state machine accepts
    /// it, reports it. Returns false (and reports nothing) otherwise. A
    /// final state ends the request's runs.
    @discardableResult
    func report(_ id: InteractionID, _ event: InteractionEvent) -> Bool {
        guard var request = requests[id] else { return false }
        do {
            try request.mirror.apply(event, at: Timestamp(clock.now()))
        } catch {
            diagnostics.refusedEvents += 1
            return false
        }
        requests[id] = request
        continuation.yield(.lifecycle(id, event))
        if request.mirror.state.isFinal { discard(id) }
        return true
    }

    /// Reports a final `event` and, if it applied, tells every friend whose
    /// run got past PSI "no plan" (`reason`), so their side ends now rather
    /// than at a timeout. Nobody's owner sees why.
    @discardableResult
    func endRequest(_ id: InteractionID, with event: InteractionEvent, telling reason: Rejection.Reason?) -> Bool {
        let told = runs.values.filter { $0.request == id && $0.phase != .psi }.map(\.notice)
        guard report(id, event) else { return false }
        if let reason { for notice in told { enqueue(.notify(notice, reason), for: notice.key.peer) } }
        return true
    }

    /// Ends the request without reporting: the coordinator applies `event`
    /// itself, as it does for a declined consent sheet.
    func endQuietly(_ id: InteractionID, _ event: InteractionEvent) {
        guard requests[id] != nil else { return }
        try? requests[id]?.mirror.apply(event, at: Timestamp(clock.now()))
        discard(id)
    }

    /// The policy refused a send for the current step: the owner's privacy
    /// topics block the request at whatever live step it was (ADR 0011,
    /// amendment 14). A planned request keeps its plan.
    func blockedByPrivacy(_ id: InteractionID) {
        guard let state = requests[id]?.mirror.state, state != .planned else { return }
        report(id, .blockedByPrivacy)
        discard(id)
    }

    func produce(_ id: InteractionID, _ artifact: Artifact) {
        continuation.yield(.produced(id, artifact))
    }

    /// Forgets a request that reached a final state, ending its runs
    /// silently. A planned request stays until its plan ends.
    func discard(_ id: InteractionID, keepingRecord: Bool = false) {
        guard let request = requests.removeValue(forKey: id) else { return }
        request.timer?.cancel()
        request.quiet?.cancel()
        request.group?.window?.cancel()
        for key in runs.keys where runs[key]?.request == id { end(key, .withdrawn) }
        cancelWork { $0.request == id }
        guard !keepingRecord else { return }
        let store = store
        Task { try? await store.remove(id) }
    }

    // MARK: - Cards

    private func learn(_ card: AgentCard, from peer: PeerID) {
        cards[peer] = card
        guard !card.support(for: DownFor.ref).isSupported else { return }
        for id in Array(requests.keys) where requests[id]?.record.participants.contains(peer) == true {
            requests[id]?.unsupported.insert(peer)
            for key in runs.keys where key.peer == peer && runs[key]?.request == id { end(key, .unsupported) }
            checkSettled(id)
        }
    }

    // MARK: - Timers

    func armExpiry(_ id: InteractionID) {
        guard let request = requests[id] else { return }
        let delay = request.record.expiresAt.date.timeIntervalSince(clock.now())
        requests[id]?.timer?.cancel()
        requests[id]?.timer = Task { [weak self, clock] in
            do { try await clock.sleep(.milliseconds(Int64(max(0, delay) * 1000))) } catch { return }
            await self?.expire(id)
        }
    }

    private func expire(_ id: InteractionID) {
        guard let request = requests[id] else { return }
        switch request.mirror.state {
        // Nobody was up for it before the request ran out.
        case .negotiating, .awaitingConsent(resume: .negotiating): endRequest(id, with: .noAgreement, telling: .expired)
        case .planned, .done, .ended: return
        default: endRequest(id, with: .expired, telling: .expired)
        }
    }

    func armPlanEnd(_ id: InteractionID) {
        guard let end = requests[id]?.mirror.plan?.endsAt else { return }
        let delay = end.timeIntervalSince(clock.now())
        requests[id]?.timer?.cancel()
        requests[id]?.timer = Task { [weak self, clock] in
            do { try await clock.sleep(.milliseconds(Int64(max(0, delay) * 1000))) } catch { return }
            await self?.report(id, .planEnded)
        }
    }

    // MARK: - Helpers

    static func unique(_ peers: [PeerID]) -> [PeerID] {
        var seen = Set<PeerID>()
        return peers.filter { seen.insert($0).inserted }
    }

    /// A request rebuilt from its interaction alone, only to report how it
    /// ended.
    static func orphan(_ interaction: Interaction, timeZone: TimeZone) -> Request {
        let record = placeholder(for: interaction)
        let profile = DownForProfile(rules: record.rules, inputs: [], expiresAt: record.expiresAt.date, timeZone: timeZone)
        return Request(record: record, profile: profile, mirror: interaction)
    }

    static func placeholder(for interaction: Interaction) -> DownForRequestRecord {
        DownForRequestRecord(SkillRequest(
            interaction: interaction.id, conversation: interaction.conversation,
            intent: SkillIntent(skill: interaction.skill, rules: .empty, audience: .picked(interaction.participants), expiresAt: interaction.createdAt),
            participants: interaction.participants
        ))
    }
}
