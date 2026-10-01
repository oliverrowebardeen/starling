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
    let ledger: any ConversationLedger
    let pairedPeers: (any PairedPeerStore)?
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
        var record: DownForRequestRecord
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
        var timer: Task<Void, Never>?
        /// Invite mode: the plan the invitation offers.
        var invitation: Terms?
        /// When this phone took the request on, for the quiet period
        /// before the starter proposes.
        var since = ContinuousClock.now
        var quiet: Task<Void, Never>?
        /// Audience checks running, each with its own window; the offers
        /// follow when one ends.
        var vettings: [UUID: Task<Void, Never>] = [:]
        /// The owner passed on the card. The request runs on unchanged,
        /// minus any I'm in from the owner, until the card's window ends
        /// (final privacy review, finding 1).
        var passed = false

        var id: InteractionID { record.interaction }
        var conversation: ConversationID { record.conversation }

        /// Still starting runs with friends: until the plan is being
        /// confirmed, a card showing or not.
        var isTakingFriends: Bool {
            mirror.state != .planned && !mirror.state.isFinal && group?.confirming == nil
        }

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
    /// Proposals on their fixed delivery schedules, by friend.
    var deliveries: [RunKey: Delivery] = [:]
    var finished: [RunKey: Finished] = [:]
    var finishedOrder: [RunKey] = []
    var reachable: Set<PeerID> = []
    /// Conversations being retired whose ledger write has not finished, so
    /// nothing slips in between. One that failed to write stays here, so
    /// the check fails closed for the rest of the session.
    var retiring: Set<ConversationID> = []
    var lastRetire: Task<Void, Never>?
    var cards: [PeerID: AgentCard] = [:]

    var workers: [PeerID: (queue: AsyncStream<Work>.Continuation, task: Task<Void, Never>)] = [:]
    /// Saves of request records, one after another so they land in order.
    var lastSave: Task<Void, Never>?
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
    ///   - outbox: The app's Outbox. Every send names its interaction in
    ///     `OutboundContext.interaction`, so the coordinator's consent
    ///     provider knows which interaction a sheet suspends (amendment 15).
    ///   - ledger: The phone's `ConversationLedger` (ADR 0021), the same one
    ///     the Outbox enforces: retired conversations open nothing and get
    ///     nothing, and endings retire through `Outbox.retire(_:)`.
    ///   - model: Used for one job: matching a starter's activities against
    ///     the owner's (ADR 0121).
    ///   - pairedPeers: When given, an invitation is shown only from a
    ///     paired friend. The secure channel admits only paired friends
    ///     anyway (ADR 0003); this is the service's own check.
    public init(
        localPeer: PeerID,
        outbox: Outbox,
        model: any AgentModel,
        psi: any PSIProvider,
        ledger: any ConversationLedger,
        store: any DownForRequestStore = InMemoryDownForRequestStore(),
        pairedPeers: (any PairedPeerStore)? = nil,
        clock: SkillClock = .system,
        timeZone: TimeZone = .current,
        configuration: DownForConfiguration = DownForConfiguration()
    ) {
        self.localPeer = localPeer
        self.outbox = outbox
        self.model = model
        self.psi = psi
        self.store = store
        self.ledger = ledger
        self.pairedPeers = pairedPeers
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
        if record.mode == .invite {
            guard let terms = invitationTerms(for: profile, now: now) else { throw DownForError.noAvailableTime }
            state.invitation = terms
        }
        requests[request.interaction] = state
        try? await store.save(record)

        guard requests[request.interaction] != nil else { return }
        if state.unsupported.count == participants.count {
            endRequest(request.interaction, with: .unsupported)
            return
        }
        armExpiry(request.interaction)
        if record.mode == .invite { armInvitationWindow(request.interaction) }
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
            // "If you pass, they just won't see it". A starter's request
            // runs on exactly as if the owner had not answered: proposals
            // keep their schedule and nobody is confirmed, and it ends when
            // the card's window does (final privacy review, finding 1).
            // The coordinator shows the pass at once (request 7).
            if request.engagement == .hub, request.invitation == nil, request.group != nil {
                guard !request.passed else { throw DownForError.notWaitingForOwner }
                requests[interaction]?.passed = true
                return
            }
            guard endRequest(interaction, with: .ownerPassed) else { throw DownForError.notWaitingForOwner }
        case .accept(let revision):
            guard !request.passed else { throw DownForError.notWaitingForOwner }
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
        endRequest(interaction, with: .withdrawn)
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
            } else if let skill = envelope.skill, skill.id == DownFor.ref.id, skill.version.isCompatible(with: DownFor.ref.version),
                      let mode = envelope.mode, descriptor.sendModes.contains(mode) {
                // A mode the skill does not offer is ignored like any unknown
                // request (ADR 0020 decision 5). A retired conversation is
                // checked on the friend's queue (ADR 0021).
                enqueue(.message(envelope), for: envelope.sender)
            }
        case .dropped:
            break
        }
    }

    /// Rebuilds after a restart. The coordinator has already closed any
    /// consent request left open (amendment 15), and passes interactions
    /// that ended in the last 24 hours too, so late retries for them are
    /// ignored rather than opened again.
    public func restore(_ interactions: [Interaction]) async {
        let now = clock.now()
        for interaction in interactions where interaction.skill.id == DownFor.ref.id && interaction.state.isFinal {
            retire(interaction.conversation)
        }
        for interaction in interactions where interaction.skill.id == DownFor.ref.id && requests[interaction.id] == nil {
            switch interaction.state {
            case .planned:
                guard let record = try? await store.record(for: interaction.id) ?? Self.placeholder(for: interaction) else { continue }
                let profile = DownForProfile(rules: record.rules, inputs: record.inputs, expiresAt: record.expiresAt.date, timeZone: timeZone)
                requests[interaction.id] = Request(record: record, profile: profile, mirror: interaction)
                armCleanup(interaction.id)
            case .negotiating where interaction.role == .initiator:
                // Runs in flight died with the old process; their peers time
                // out. Start fresh ones under the same conversation.
                guard let record = try? await store.record(for: interaction.id), record.expiresAt.date > now else {
                    requests[interaction.id] = Self.orphan(interaction, timeZone: timeZone)
                    endRequest(interaction.id, with: .failed)
                    continue
                }
                let profile = DownForProfile(rules: record.rules, inputs: record.inputs, expiresAt: record.expiresAt.date, timeZone: timeZone)
                var restored = Request(record: record, profile: profile, mirror: interaction)
                // Runs already spent stay spent.
                restored.runs = record.runDebits ?? [:]
                requests[interaction.id] = restored
                armExpiry(interaction.id)
                for peer in record.participants { enqueue(.start(interaction.id), for: peer) }
            case .done, .ended:
                continue
            default:
                // A consent sheet, a card, or a group in flight cannot be
                // rebuilt: the sheet is gone, and so is the starter's group.
                requests[interaction.id] = Self.orphan(interaction, timeZone: timeZone)
                endRequest(interaction.id, with: .failed)
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
    /// final event goes through `endRequest`.
    @discardableResult
    func report(_ id: InteractionID, _ event: InteractionEvent) -> Bool {
        guard var request = requests[id] else { return false }
        var mirror = request.mirror
        do {
            try mirror.apply(event, at: Timestamp(clock.now()))
        } catch {
            diagnostics.refusedEvents += 1
            return false
        }
        if mirror.state.isFinal { return endRequest(id, with: event) }
        request.mirror = mirror
        requests[id] = request
        // After a pass the owner sees nothing more until the ending.
        if !request.passed { continuation.yield(.lifecycle(id, event)) }
        return true
    }

    /// Ends a request with a final `event`. Its runs, timers, and sends
    /// stop at once, and the local copy takes the final state, so nothing
    /// can start it again. Its conversations are then retired through
    /// `Outbox.retire(_:)`, and only once that is durable is `event`
    /// reported (ADR 0021, lane E's review): a crash in between can never
    /// leave an ended interaction whose conversation is still open. If
    /// retiring fails, the request is reported as failed instead of the
    /// clean ending, and its conversations stay refused here.
    ///
    /// Nothing is sent to friends: a pass, a withdrawal, an expiry, or a
    /// group that fell apart all look like someone who stopped answering
    /// (review of PR #56, finding 4).
    @discardableResult
    func endRequest(_ id: InteractionID, with event: InteractionEvent) -> Bool {
        guard var request = requests[id] else { return false }
        do {
            try request.mirror.apply(event, at: Timestamp(clock.now()))
        } catch {
            diagnostics.refusedEvents += 1
            return false
        }
        guard request.mirror.state.isFinal else { return report(id, event) }
        // Its own conversation (for an invitee, the invitation), and the
        // starter's conversation of a card it showed.
        var conversations = [request.conversation]
        if case .member(let key) = request.engagement, request.mirror.proposal != nil, key.conversation != request.conversation {
            conversations.append(key.conversation)
        }
        requests[id] = request
        discard(id)
        retiring.formUnion(conversations)
        let outbox = outbox
        Task { [weak self] in
            var retired = true
            for conversation in conversations {
                do { try await outbox.retire(conversation) } catch { retired = false }
            }
            await self?.publishEnding(id, retired ? event : .failed, conversations: retired ? conversations : [])
        }
        return true
    }

    /// Reports an ending once its retirement is settled. `conversations`
    /// are the ones now durably retired, which need no local refusal.
    private func publishEnding(_ id: InteractionID, _ event: InteractionEvent, conversations: [ConversationID]) {
        retiring.subtract(conversations)
        continuation.yield(.lifecycle(id, event))
    }

    /// Ends the request without reporting: the coordinator applies `event`
    /// itself, as it does for a declined consent sheet. Its conversation is
    /// still retired.
    func endQuietly(_ id: InteractionID, _ event: InteractionEvent) {
        guard let request = requests[id] else { return }
        try? requests[id]?.mirror.apply(event, at: Timestamp(clock.now()))
        discard(id)
        retire(request.conversation)
    }

    /// The policy refused a send for the current step: the owner's privacy
    /// topics block the request at whatever live step it was (ADR 0011,
    /// amendment 14). A planned request keeps its plan.
    func blockedByPrivacy(_ id: InteractionID) {
        guard let state = requests[id]?.mirror.state, state != .planned else { return }
        endRequest(id, with: .blockedByPrivacy)
    }

    func produce(_ id: InteractionID, _ artifact: Artifact) {
        requests[id]?.mirror.record(artifact)
        continuation.yield(.produced(id, artifact))
    }

    /// Changes a request's PSI run count with `friend` and saves it with the
    /// request record, so the run cap survives a restart.
    func debitRun(_ id: InteractionID, _ friend: PeerID, by change: Int) {
        guard var request = requests[id] else { return }
        request.runs[friend] = max(0, request.runs[friend, default: 0] + change)
        request.record.runDebits = request.runs
        requests[id] = request
        guard request.mirror.role == .initiator else { return }
        let record = request.record
        let store = store
        let previous = lastSave
        lastSave = Task {
            await previous?.value
            try? await store.save(record)
        }
    }

    /// Ends `conversation` for good through `Outbox.retire(_:)` (ADR 0021):
    /// the ledger records it and its sends still in flight are cancelled.
    /// In order, one after another.
    func retire(_ conversation: ConversationID) {
        guard retiring.insert(conversation).inserted else { return }
        let outbox = outbox
        let previous = lastRetire
        lastRetire = Task { [weak self] in
            await previous?.value
            do {
                try await outbox.retire(conversation)
                await self?.retired(conversation)
            } catch {
                // Not recorded: keep refusing it here, fail closed.
            }
        }
    }

    private func retired(_ conversation: ConversationID) { retiring.remove(conversation) }

    /// Whether anything in `conversation` may still be answered or opened.
    /// A ledger that cannot say counts as retired.
    func isRetired(_ conversation: ConversationID) async -> Bool {
        if retiring.contains(conversation) { return true }
        return (try? await ledger.isRetired(conversation)) ?? true
    }

    /// Forgets a request that reached a final state, ending its runs
    /// silently. A planned request stays until its plan ends.
    func discard(_ id: InteractionID, keepingRecord: Bool = false) {
        guard let request = requests.removeValue(forKey: id) else { return }
        // Retiring is the caller's: `endRequest` before it reports an
        // ending, the plan's cleanup, or nobody for a shutdown. A group it
        // only answered stays open, since that starter may ask again,
        // unless its card had shown (`end`).
        request.timer?.cancel()
        request.quiet?.cancel()
        for task in request.vettings.values { task.cancel() }
        for key in deliveries.keys where deliveries[key]?.request == id { stopDelivery(key) }
        request.group?.window?.cancel()
        for key in runs.keys where runs[key]?.request == id { end(key, .withdrawn) }
        cancelWork { $0.request == id }
        // A plan's cached replies go with it: nothing is replayed for a
        // request that ended (review of PR #56, finding 2).
        for key in finished.keys where finished[key]?.request == id { finished[key] = nil }
        finishedOrder.removeAll { finished[$0] == nil }
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
        case .negotiating, .awaitingConsent(resume: .negotiating): endRequest(id, with: .noAgreement)
        case .planned, .done, .ended: return
        default: endRequest(id, with: .expired)
        }
    }

    /// How long after a plan ends its request is kept, to answer a member's
    /// late retry with the confirmation it lost.
    static let planGrace: TimeInterval = 30 * 60

    /// Forgets a planned request a while after its plan ends. The
    /// coordinator applies `planEnded` itself (ADR 0011, amendment 15), so
    /// this reports nothing.
    func armCleanup(_ id: InteractionID) {
        guard let end = requests[id]?.mirror.plan?.endsAt else { return }
        let delay = end.addingTimeInterval(Self.planGrace).timeIntervalSince(clock.now())
        requests[id]?.timer?.cancel()
        requests[id]?.timer = Task { [weak self, clock] in
            do { try await clock.sleep(.milliseconds(Int64(max(0, delay) * 1000))) } catch { return }
            await self?.forgetPlan(id)
        }
    }

    /// The plan is over: its conversation is retired and the request is
    /// forgotten. The coordinator reports the plan's end itself.
    private func forgetPlan(_ id: InteractionID) {
        guard let request = requests[id] else { return }
        discard(id)
        retire(request.conversation)
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
            intent: SkillIntent(
                skill: interaction.skill, rules: .empty, audience: .picked(interaction.participants),
                mode: interaction.role == .invitee ? .invite : .askQuietly, expiresAt: interaction.createdAt
            ),
            participants: interaction.participants
        ))
    }
}
