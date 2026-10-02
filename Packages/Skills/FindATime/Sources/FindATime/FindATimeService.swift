import Foundation
import StarlingAvailability
import StarlingCore

/// The Find a time skill's runtime (ADR 0221).
///
/// The starter offers up to `maxCandidates` times it is free for, as one
/// private query per friend. Each friend's agent answers with the offered
/// times its owner is free for, from the calendar when it can read one and
/// otherwise by asking the owner one question. The starter picks the time
/// the most friends can make, proposes it, and when everyone in it says
/// "That works", confirms. Both sides then produce a `TimeSlot` and a `Plan`.
///
/// The service never asks for the calendar permission: it only reads its
/// status through `OwnerAvailability`, so a friend's request can never raise
/// a system alert (ARCHITECTURE rule 8). Every send goes through the app's
/// `Outbox` with the skill's `SkillRef`; every receive comes through `handle(_:)`.
///
/// State changes run on the actor without suspending. Sends and calendar
/// reads run in their own tasks and report back, so a consent sheet or a
/// slow read never holds up another conversation.
public actor FindATimeService: SkillService {
    public nonisolated let descriptor = FindATimeSkill.descriptor
    public nonisolated let events: AsyncStream<SkillEvent>
    private let continuation: AsyncStream<SkillEvent>.Continuation

    let localPeer: PeerID
    let outbox: Outbox
    let pairedPeers: any PairedPeerStore
    let availability: OwnerAvailability
    let clock: FindATimeClock
    let timeZone: TimeZone
    let configuration: FindATimeConfiguration
    let isTurnedOn: @Sendable () async -> Bool
    let standingRules: @Sendable () async -> ConstraintSet

    var initiating: [ConversationID: Initiating] = [:]
    var invited: [ConversationID: Invited] = [:]
    var conversationOf: [InteractionID: ConversationID] = [:]
    /// Conversations that ended, so late messages never reopen them.
    var finished: [ConversationID: Tombstone] = [:]
    private var finishedOrder: [ConversationID] = []
    /// Sends of the current step to each friend, for the retry limit.
    var attempts: [ConversationID: [PeerID: Int]] = [:]
    var cards: [PeerID: AgentCard] = [:]
    private var tickers: [ConversationID: Task<Void, Never>] = [:]
    private var effects: [UUID: Task<Void, Never>] = [:]
    /// Each conversation's work in flight (sends, calendar reads), so
    /// ending or withdrawing it cancels a send still waiting on a consent
    /// sheet or the policy recheck: Outbox checks cancellation before the
    /// transport, so nothing of it leaves afterwards.
    private var effectsOf: [ConversationID: Set<UUID>] = [:]
    private var conversationOfEffect: [UUID: ConversationID] = [:]
    private let checkpointQueue: AsyncStream<CheckpointOp>.Continuation
    private let checkpointTask: Task<Void, Never>
    private var isShutDown = false
    private var pending: Set<SendKey> = []
    /// Replies that name an envelope not yet recorded because its send has
    /// not returned (Outbox may still be awaiting its observer after the
    /// friend has already answered, issue #105). Held only while such a send
    /// to that friend is in flight, at most `maxEarlyReplies` per friend,
    /// and checked against the record once the send returns. Never counted
    /// without naming something actually sent (#68).
    private var earlyReplies: [ConversationID: [PeerID: [Envelope]]] = [:]
    static let maxEarlyReplies = 4
    private var checkpointsClosed = false

    struct Tombstone: Hashable, Sendable {
        /// The starter, for an invitee conversation.
        let asker: PeerID?
        /// The ended interaction, so its last "no plan" still names it.
        let interaction: InteractionID?
    }

    enum CheckpointOp: Sendable {
        case save(FindATimeCheckpoint)
        case remove(InteractionID)
        case flush(CheckedContinuation<Void, Never>)
    }

    /// For tests and logs. Never shown to the owner or sent.
    struct Diagnostics: Hashable, Sendable {
        var ignored: [String: Int] = [:]
        /// Events the lifecycle would refuse, caught before they were emitted.
        var unappliedEvents = 0
        var sends = 0
        var failedSends = 0
        var retireFailures = 0
    }

    private(set) var diagnostics = Diagnostics()

    static let maxTombstones = 256
    /// The app's one `ConversationLedger`, shared with its Outbox (ADR 0021):
    /// retired conversations are never opened again, and every candidate a
    /// friend is answered about is reserved there.
    let conversations: any ConversationLedger
    /// The last "no plan" of each ending conversation, which must leave
    /// before the conversation is retired (retiring cancels its sends).
    private var lastWords: [ConversationID: [Task<Void, Never>]] = [:]

    /// - Parameters:
    ///   - localPeer: This phone's ID (the Outbox transport's `localPeer`).
    ///   - outbox: The app's single Outbox, with its policy and consent sheet.
    ///   - pairedPeers: Only these friends' messages are handled.
    ///   - availability: Usually `OwnerAvailability.standard(calendar:use:stated:)`.
    ///   - checkpoints: Where conversations are saved so `restore(_:)` can
    ///     resume them after a restart. Pass a persistent store in the app.
    ///   - isTurnedOn: Whether the owner has Find a time switched on. When
    ///     off, friends' requests are ignored.
    ///   - conversations: The app's `ConversationLedger`, the same one its
    ///     Outbox enforces (ADR 0021).
    ///   - standingRules: The owner's standing hard limits ("no plans
    ///     before 10"). A friend's request is answered and its proposals
    ///     accepted only within them. The owner's own requests arrive with
    ///     them already merged into the intent.
    public init(
        localPeer: PeerID,
        outbox: Outbox,
        conversations: any ConversationLedger,
        pairedPeers: any PairedPeerStore,
        availability: OwnerAvailability,
        checkpoints: any FindATimeCheckpointStore = InMemoryFindATimeCheckpoints(),
        clock: FindATimeClock = .system,
        timeZone: TimeZone = .current,
        configuration: FindATimeConfiguration = FindATimeConfiguration(),
        isTurnedOn: @escaping @Sendable () async -> Bool = { true },
        standingRules: @escaping @Sendable () async -> ConstraintSet = { .empty }
    ) {
        self.localPeer = localPeer
        self.outbox = outbox
        self.conversations = conversations
        self.pairedPeers = pairedPeers
        self.availability = availability
        self.clock = clock
        self.timeZone = timeZone
        self.configuration = configuration
        self.isTurnedOn = isTurnedOn
        self.standingRules = standingRules
        (events, continuation) = AsyncStream.makeStream(of: SkillEvent.self)
        let (stream, queue) = AsyncStream.makeStream(of: CheckpointOp.self)
        checkpointQueue = queue
        checkpointTask = Task {
            for await op in stream {
                switch op {
                case .save(let checkpoint): try? await checkpoints.save(checkpoint)
                case .remove(let id): try? await checkpoints.remove(id)
                case .flush(let done): done.resume()
                }
            }
        }
        checkpointStore = checkpoints
    }

    let checkpointStore: any FindATimeCheckpointStore

    // MARK: - SkillService

    public func start(_ request: SkillRequest) async throws {
        try startInitiating(request)
    }

    public func answer(_ interaction: InteractionID, with answer: OwnerAnswer) async throws {
        guard let id = conversationOf[interaction] else { throw FindATimeError.unknownInteraction }
        if initiating[id] != nil {
            try initiatorAnswer(id, answer)
        } else if invited[id] != nil {
            try inviteeAnswer(id, answer)
        } else {
            throw FindATimeError.unknownInteraction
        }
    }

    public func withdraw(_ interaction: InteractionID) async {
        guard let id = conversationOf[interaction] else { return }
        if initiating[id] != nil { initiatorWithdraw(id) } else if invited[id] != nil { inviteeWithdraw(id) }
    }

    public func handle(_ event: InboxEvent) async {
        guard !isShutDown else { return }
        switch event {
        case .peerAvailable(let peer):
            resendAll(to: peer)
        case .peerUnavailable, .dropped:
            break
        case .message(let envelope):
            if case .hello(let card) = envelope.body {
                cards[envelope.sender] = card
                return
            }
            guard let skill = envelope.skill, skill.id == FindATimeSkill.ref.id else { return }
            guard skill.version.isCompatible(with: FindATimeSkill.ref.version) else { return ignore("incompatible version") }
            // A mode the skill does not offer is ignored like any unknown
            // request: a quiet ask never becomes a card (ADR 0020).
            guard let mode = envelope.mode, descriptor.sendModes.contains(mode) else { return ignore("unsupported mode") }
            guard envelope.recipient == localPeer, envelope.sender != localPeer else { return ignore("misaddressed") }
            guard await isPaired(envelope.sender) else { return ignore("not a friend") }
            switch envelope.body {
            case .query(let query):
                guard await isTurnedOn() else { return ignore("turned off") }
                guard await mayOpen(envelope, query) else { return }
                receiveQuery(envelope, query)
            case .answer(let answer): receiveAnswer(envelope, answer)
            case .propose(let proposal): receiveProposal(envelope, proposal)
            case .accept(let acceptance):
                if initiating[envelope.conversation] != nil { receiveAcceptance(envelope, acceptance) } else { receiveConfirmation(envelope, acceptance) }
            case .reject(let rejection):
                if initiating[envelope.conversation] != nil { receiveInitiatorRejection(envelope, rejection) } else { receiveInviteeRejection(envelope) }
            case .hello, .counter, .psi:
                ignore("unexpected \(envelope.body.kind)")
            }
        }
    }

    public func restore(_ interactions: [Interaction]) async {
        let saved = (try? await checkpointStore.all()) ?? []
        resume(interactions, from: saved)
    }

    public func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        for task in tickers.values { task.cancel() }
        for task in effects.values { task.cancel() }
        for task in lastWords.values.flatMap({ $0 }) { task.cancel() }
        lastWords = [:]
        tickers = [:]
        effects = [:]
        continuation.finish()
        await flushCheckpoints()
        checkpointsClosed = true
        checkpointQueue.finish()
    }

    // MARK: - Shared machinery

    func now() -> Date { clock.now() }

    func ignore(_ reason: String) {
        diagnostics.ignored[reason, default: 0] += 1
    }

    private func isPaired(_ peer: PeerID) async -> Bool {
        guard let paired = try? await pairedPeers.peer(for: peer) else { return false }
        return paired.id == peer
    }

    /// Applies `event` to the service's copy of the interaction and emits it
    /// only if the lifecycle accepts it, so the coordinator never receives
    /// an event that would be dropped as invalid or stale.
    @discardableResult
    func emit(_ event: InteractionEvent, to interaction: inout Interaction) -> Bool {
        do {
            try interaction.apply(event, at: Timestamp(now()))
        } catch {
            diagnostics.unappliedEvents += 1
            return false
        }
        continuation.yield(.lifecycle(interaction.id, event))
        return true
    }

    func produce(_ artifact: Artifact, for interaction: InteractionID) {
        continuation.yield(.produced(interaction, artifact))
    }

    func announceIncoming(_ value: Invited) {
        continuation.yield(.incoming(value.interaction.id, conversation: value.conversation, from: value.asker, chainedFrom: value.chainedFrom))
    }

    /// Runs side-effect work (sends, calendar reads) off the state machine.
    /// Work for a conversation is cancelled when the conversation ends;
    /// work for none (the final "no plan") is not.
    func spawn(for conversation: ConversationID?, _ work: @escaping @Sendable () async -> Void) {
        guard !isShutDown else { return }
        let key = UUID()
        if let conversation {
            effectsOf[conversation, default: []].insert(key)
            conversationOfEffect[key] = conversation
        }
        effects[key] = Task {
            await work()
            self.effectFinished(key)
        }
    }

    private func effectFinished(_ key: UUID) {
        effects[key] = nil
        if let conversation = conversationOfEffect.removeValue(forKey: key) {
            effectsOf[conversation]?.remove(key)
            if effectsOf[conversation]?.isEmpty == true { effectsOf[conversation] = nil }
        }
    }

    private func cancelWork(of conversation: ConversationID) {
        for key in effectsOf.removeValue(forKey: conversation) ?? [] {
            effects.removeValue(forKey: key)?.cancel()
            conversationOfEffect[key] = nil
        }
    }

    func register(_ conversation: ConversationID, interaction: InteractionID) {
        conversationOf[interaction] = conversation
        startTicker(conversation)
    }

    /// Whether a send of `step` ("query", or any proposal round when nil)
    /// to `peer` in `conversation` is still in flight.
    func sendInFlight(_ conversation: ConversationID, to peer: PeerID, step: String?) -> Bool {
        pending.contains { key in
            key.conversation == conversation && key.peer == peer && (step.map { key.step == $0 } ?? key.step.hasPrefix("propose "))
        }
    }

    /// Holds a reply until the send it may name returns. Returns false if no
    /// such send is in flight, so the caller ignores it as before.
    func holdEarly(_ envelope: Envelope, step: String?) -> Bool {
        guard sendInFlight(envelope.conversation, to: envelope.sender, step: step) else { return false }
        var held = earlyReplies[envelope.conversation, default: [:]][envelope.sender, default: []]
        held.append(envelope)
        earlyReplies[envelope.conversation, default: [:]][envelope.sender] = Array(held.suffix(Self.maxEarlyReplies))
        ignore("reply held until its send returns")
        return true
    }

    /// Checks the replies held for `peer` again, now that a send's envelope
    /// is recorded. Each counts only if it names something recorded.
    func recheckEarly(_ conversation: ConversationID, from peer: PeerID) {
        guard let held = earlyReplies[conversation]?.removeValue(forKey: peer), !held.isEmpty else { return }
        for envelope in held {
            switch envelope.body {
            case .answer(let answer): receiveAnswer(envelope, answer)
            case .accept(let acceptance): receiveAcceptance(envelope, acceptance)
            case .reject(let rejection): receiveInitiatorRejection(envelope, rejection)
            default: break
            }
        }
    }

    func dropEarly(_ conversation: ConversationID) { earlyReplies[conversation] = nil }

    /// Ends a conversation on this phone: its work stops at once, and once
    /// its last "no plan" has left, it is retired for good through Outbox
    /// (ADR 0021). Nothing is sent in it, and nothing is opened for it, again.
    ///
    /// The terminal `event` is reported only after the retirement is
    /// recorded, so no ending is ever published for a conversation that a
    /// fresh request could still reopen. If retiring throws, `failed` is
    /// reported instead, and the conversation stays closed on this phone and
    /// is retired again at the next launch. `nil` reports nothing (a plan
    /// whose time passed: the coordinator applies `planEnded`).
    func close(_ conversation: ConversationID, reporting event: InteractionEvent?) {
        var copy = initiating[conversation]?.interaction ?? invited[conversation]?.interaction
        let interaction = copy?.id
        let asker = invited[conversation]?.asker
        // Decide now, on the service's copy, which event the lifecycle will
        // accept; it is published after the retirement.
        var report: InteractionEvent?
        if let event, copy != nil {
            if (try? copy?.apply(event, at: Timestamp(now()))) != nil {
                report = event
            } else if (try? copy?.apply(.failed, at: Timestamp(now()))) != nil {
                report = .failed
            } else {
                diagnostics.unappliedEvents += 1
            }
        }
        initiating[conversation] = nil
        invited[conversation] = nil
        attempts[conversation] = nil
        tickers.removeValue(forKey: conversation)?.cancel()
        cancelWork(of: conversation)
        if let interaction { conversationOf[interaction] = nil }
        dropEarly(conversation)
        remember(conversation, asker: asker, interaction: interaction)
        retire(conversation, interaction: interaction, asker: asker, report: report)
    }

    /// Retires `conversation` once its last "no plan" has gone, then reports.
    /// A checkpoint marks it retiring until the ledger has it, so shutting
    /// down first never leaves it open: restore retires it again.
    func retire(_ conversation: ConversationID, interaction: InteractionID?, asker: PeerID?, report: InteractionEvent?) {
        if let interaction {
            checkpointQueue.yield(.save(FindATimeCheckpoint(state: .retiring(conversation: conversation, interaction: interaction, asker: asker, report: report))))
        }
        let words = lastWords.removeValue(forKey: conversation) ?? []
        let outbox = outbox
        spawn(for: nil) {
            for word in words { await word.value }
            let retired: Bool
            do {
                try await outbox.retire(conversation)
                retired = true
            } catch {
                retired = false
            }
            await self.retired(conversation, interaction: interaction, asker: asker, report: report, succeeded: retired)
        }
    }

    private func retired(_ conversation: ConversationID, interaction: InteractionID?, asker: PeerID?, report: InteractionEvent?, succeeded: Bool) {
        guard let interaction else { return }
        if succeeded {
            if let report { continuation.yield(.lifecycle(interaction, report)) }
            checkpointQueue.yield(.remove(interaction))
        } else {
            // Not a clean ending: the conversation could not be closed for
            // good. It stays closed in memory and in its checkpoint, and the
            // next launch retires it again.
            diagnostics.retireFailures += 1
            if report != nil { continuation.yield(.lifecycle(interaction, .failed)) }
            // Failed is reported; the next launch only retires it.
            checkpointQueue.yield(.save(FindATimeCheckpoint(state: .retiring(conversation: conversation, interaction: interaction, asker: asker, report: nil))))
        }
    }

    /// Whether a friend's query may open an invitee interaction: not in a
    /// retired conversation, and only if the ledger reserves its candidates
    /// (at most 16 per friend and conversation, ADR 0021). A ledger that
    /// cannot answer refuses. A retry for a request already open passes.
    private func mayOpen(_ envelope: Envelope, _ query: Query) async -> Bool {
        let id = envelope.conversation
        if initiating[id] != nil || invited[id] != nil || finished[id] != nil { return true }
        guard let candidates = QueryCheck.candidates(of: query, now: now(), configuration: configuration) else { return true }
        do {
            guard try await !conversations.isRetired(id) else {
                ignore("retired conversation")
                return false
            }
            guard try await conversations.reserve(candidates.map { .slots([$0]) }, issue: .time, to: envelope.sender, in: id) else {
                ignore("answer budget spent")
                return false
            }
            return true
        } catch {
            ignore("ledger unavailable")
            return false
        }
    }

    /// Keeps ended conversations in memory until they are retired, so a late
    /// message meanwhile opens nothing. The ledger is the lasting record.
    func remember(_ conversation: ConversationID, asker: PeerID?, interaction: InteractionID?) {
        guard finished[conversation] == nil else { return }
        finished[conversation] = Tombstone(asker: asker, interaction: interaction)
        finishedOrder.append(conversation)
        if finishedOrder.count > Self.maxTombstones { finished[finishedOrder.removeFirst()] = nil }
    }

    func removeCheckpoint(_ interaction: InteractionID) {
        checkpointQueue.yield(.remove(interaction))
    }

    func checkpoint(_ conversation: ConversationID) {
        if let value = initiating[conversation] {
            checkpointQueue.yield(.save(FindATimeCheckpoint(state: .initiating(value))))
        } else if let value = invited[conversation] {
            checkpointQueue.yield(.save(FindATimeCheckpoint(state: .invited(value))))
        }
    }

    /// Waits until every checkpoint write queued so far has finished.
    /// Returns at once after shutdown, when the queue no longer runs.
    func flushCheckpoints() async {
        guard !checkpointsClosed else { return }
        await withCheckedContinuation { continuation in
            if case .terminated = checkpointQueue.yield(.flush(continuation)) { continuation.resume() }
        }
    }

    // MARK: - Sending

    enum SendOutcome: Sendable {
        case sent(Envelope)
        /// The owner declined the consent sheet.
        case declined
        /// The policy refused, for example a topic set to Never.
        case denied(PolicyViolation)
        /// Unreachable or changed during consent: a retry may succeed.
        case failed
        /// The conversation ledger or the numbering refused for good: retired,
        /// over the answer limit (ADR 0021).
        case refused
    }

    /// One step's send to one friend. A retry of a step whose send is still
    /// pending (on a consent sheet, say) is skipped, so a retry never opens
    /// a second sheet for the same message.
    struct SendKey: Hashable, Sendable {
        let conversation: ConversationID
        let peer: PeerID
        let step: String

        init?(_ body: MessageBody, to peer: PeerID, in conversation: ConversationID) {
            let step: String
            switch body {
            case .query: step = "query"
            case .answer: step = "answer"
            case .propose(let proposal): step = "propose \(proposal.round)"
            case .accept(let acceptance): step = "accept \(acceptance.terms.hashValue)"
            default: return nil
            }
            self.conversation = conversation
            self.peer = peer
            self.step = step
        }
    }

    /// What a successful send records before anything else runs: the
    /// envelope a friend's reply must name (#68, #105).
    enum Record: Sendable {
        case query
        case proposal(revision: UInt32)
    }

    func send(_ body: MessageBody, to peer: PeerID, conversation: ConversationID, chainedFrom: ConversationID?, record: Record? = nil) async -> SendOutcome {
        let key = SendKey(body, to: peer, in: conversation)
        if let key {
            // Reported like a lost send: the next retry tries again.
            guard pending.insert(key).inserted else { return .failed }
        }
        defer { if let key { pending.remove(key) } }
        // Every send names its interaction (Core v2.1), so the consent sheet
        // suspends the right one; an answer also names the friend's query,
        // so the policy can see it only says yes or no (ADR 0019).
        let interaction = initiating[conversation]?.interaction.id ?? invited[conversation]?.interaction.id ?? finished[conversation]?.interaction
        let answering: Query? = if case .answer = body { invited[conversation]?.query } else { nil }
        // A friend's acceptance repeats exactly the starter's proposal, so it
        // goes like a yes (ADR 0019 amendment 10). The starter's own
        // confirmation repeats its own terms and stays under the topics.
        let accepting: Proposal? = if case .accept = body { invited[conversation]?.offer?.proposal } else { nil }
        do {
            let envelope = try await outbox.send(
                body, to: peer, conversation: conversation, recipientCard: cards[peer],
                context: OutboundContext(answering: answering, interaction: interaction, accepting: accepting),
                skill: FindATimeSkill.ref, mode: .invite, chainedFrom: chainedFrom
            )
            diagnostics.sends += 1
            // Record it here, on this actor, before returning and while the
            // send still counts as in flight: a reply already held can then
            // be matched, and no retry slips in between (issue #105).
            switch record {
            case .query?: recordQuery(conversation, to: peer, envelope.id)
            case .proposal(let revision)?: recordProposal(conversation, revision: revision, to: peer, envelope.id)
            case nil: break
            }
            return .sent(envelope)
        } catch OutboxError.consentDeclined {
            return .declined
        } catch OutboxError.denied(let violation) {
            return .denied(violation)
        } catch OutboxError.conversationRetired, OutboxError.answerLimitReached, OutboxError.answerWithoutItsQuery, OutboxError.sequenceExhausted {
            // The ledger or the numbering refuses for good (ADR 0021).
            return .refused
        } catch {
            diagnostics.failedSends += 1
            return .failed
        }
    }

    /// "No plan", which is all a friend learns from any ending (ADR 0221):
    /// always `noOverlap`, whether the cause was no time, a pass, a declined
    /// sheet, or a Never setting (ADR 0019, decision 5).
    func sendNoPlan(about message: MessageID, to peers: [PeerID], in conversation: ConversationID, chainedFrom: ConversationID?) {
        guard !peers.isEmpty, !isShutDown else { return }
        // Not tied to the conversation's work, which ending cancels: it is
        // what is sent as it ends, and retiring waits for it.
        let word = Task {
            for peer in peers {
                _ = await self.send(.reject(Rejection(proposal: message, reason: .noOverlap)), to: peer, conversation: conversation, chainedFrom: chainedFrom)
            }
        }
        lastWords[conversation, default: []].append(word)
    }

    func countAttempt(_ conversation: ConversationID, _ peer: PeerID) -> Bool {
        let used = attempts[conversation, default: [:]][peer, default: 0]
        guard used < configuration.maxAttempts else { return false }
        attempts[conversation, default: [:]][peer] = used + 1
        return true
    }

    func resetAttempts(_ conversation: ConversationID) { attempts[conversation] = [:] }

    // MARK: - Timers

    private func startTicker(_ conversation: ConversationID) {
        guard tickers[conversation] == nil, !isShutDown else { return }
        let interval = configuration.retryInterval
        let sleep = clock.sleep
        tickers[conversation] = Task {
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard self.tick(conversation) else { return }
            }
        }
    }

    /// Deadlines and retries for one conversation. Returns false once the
    /// conversation is gone.
    private func tick(_ conversation: ConversationID) -> Bool {
        if initiating[conversation] != nil {
            initiatorTick(conversation)
        } else if invited[conversation] != nil {
            inviteeTick(conversation)
        }
        return initiating[conversation] != nil || invited[conversation] != nil
    }

    /// A friend's link came back: send what they are still waiting on.
    private func resendAll(to peer: PeerID) {
        for id in Array(initiating.keys) where initiating[id]?.waitingOn.contains(peer) == true {
            attempts[id]?[peer] = 0
            initiatorResend(id, to: [peer])
        }
        for id in Array(invited.keys) where invited[id]?.asker == peer && invited[id]?.phase == .accepted {
            attempts[id]?[peer] = 0
            inviteeResendAcceptance(id)
        }
    }

    func expired(_ deadline: Timestamp?) -> Bool {
        guard let deadline else { return false }
        return Timestamp(now()) >= deadline
    }

    func deadline(after wait: Duration, capped cap: Timestamp) -> Timestamp {
        min(cap, Timestamp(now().addingTimeInterval(wait.timeInterval)))
    }
}
