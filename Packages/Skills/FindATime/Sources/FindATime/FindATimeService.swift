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

    struct Tombstone: Hashable, Sendable {
        /// The starter, for an invitee conversation: a late query or
        /// proposal from it gets "no plan" again, never a new card.
        let asker: PeerID?
        var replies = 0
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
    }

    private(set) var diagnostics = Diagnostics()

    static let maxTombstones = 256

    /// - Parameters:
    ///   - localPeer: This phone's ID (the Outbox transport's `localPeer`).
    ///   - outbox: The app's single Outbox, with its policy and consent sheet.
    ///   - pairedPeers: Only these friends' messages are handled.
    ///   - availability: Usually `OwnerAvailability.standard(calendar:use:stated:)`.
    ///   - checkpoints: Where conversations are saved so `restore(_:)` can
    ///     resume them after a restart. Pass a persistent store in the app.
    ///   - isTurnedOn: Whether the owner has Find a time switched on. When
    ///     off, friends' requests are ignored.
    ///   - standingRules: The owner's standing hard limits ("no plans
    ///     before 10"). A friend's request is answered and its proposals
    ///     accepted only within them. The owner's own requests arrive with
    ///     them already merged into the intent.
    public init(
        localPeer: PeerID,
        outbox: Outbox,
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
            guard envelope.recipient == localPeer, envelope.sender != localPeer else { return ignore("misaddressed") }
            guard await isPaired(envelope.sender) else { return ignore("not a friend") }
            switch envelope.body {
            case .query(let query):
                guard await isTurnedOn() else { return ignore("turned off") }
                receiveQuery(envelope, query)
            case .answer(let answer): receiveAnswer(envelope, answer)
            case .propose(let proposal): receiveProposal(envelope, proposal)
            case .accept(let acceptance):
                if initiating[envelope.conversation] != nil { receiveAcceptance(envelope, acceptance) } else { receiveConfirmation(envelope, acceptance) }
            case .reject:
                if initiating[envelope.conversation] != nil { receiveInitiatorRejection(envelope) } else { receiveInviteeRejection(envelope) }
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
        tickers = [:]
        effects = [:]
        continuation.finish()
        await flushCheckpoints()
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

    /// Forgets a conversation. Late messages for it get at most "no plan".
    func finish(_ conversation: ConversationID) {
        let interaction = initiating[conversation]?.interaction.id ?? invited[conversation]?.interaction.id
        let asker = invited[conversation]?.asker
        initiating[conversation] = nil
        invited[conversation] = nil
        attempts[conversation] = nil
        tickers.removeValue(forKey: conversation)?.cancel()
        cancelWork(of: conversation)
        if let interaction {
            conversationOf[interaction] = nil
            checkpointQueue.yield(.remove(interaction))
        }
        finished[conversation] = Tombstone(asker: asker)
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
    func flushCheckpoints() async {
        await withCheckedContinuation { checkpointQueue.yield(.flush($0)) }
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
    }

    func send(_ body: MessageBody, to peer: PeerID, conversation: ConversationID, chainedFrom: ConversationID?) async -> SendOutcome {
        do {
            let envelope = try await outbox.send(
                body, to: peer, conversation: conversation, recipientCard: cards[peer],
                skill: FindATimeSkill.ref, chainedFrom: chainedFrom
            )
            diagnostics.sends += 1
            return .sent(envelope)
        } catch OutboxError.consentDeclined {
            return .declined
        } catch OutboxError.denied(let violation) {
            return .denied(violation)
        } catch {
            diagnostics.failedSends += 1
            return .failed
        }
    }

    /// "No plan", which is all a friend learns from any ending (ADR 0221).
    func sendNoPlan(_ reason: Rejection.Reason = .noOverlap, about message: MessageID, to peers: [PeerID], in conversation: ConversationID, chainedFrom: ConversationID?) {
        guard !peers.isEmpty else { return }
        // Not tied to the conversation: it is what is sent as it ends.
        spawn(for: nil) {
            for peer in peers {
                _ = await self.send(.reject(Rejection(proposal: message, reason: reason)), to: peer, conversation: conversation, chainedFrom: chainedFrom)
            }
        }
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
