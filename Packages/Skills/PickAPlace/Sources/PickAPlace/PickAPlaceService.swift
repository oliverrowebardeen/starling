import Foundation
import StarlingCore

public enum PickAPlaceError: Error, Hashable, Sendable {
    /// The request is for another skill, or another major version.
    case wrongSkill
    case alreadyStarted
    /// Compose produced no candidates; the owner should search or type one.
    case noCandidates
    /// None of the candidates fit the owner's own limits.
    case nothingFitsYourLimits
    case unknownInteraction
    /// The interaction is not waiting for this answer.
    case notWaitingForYou
    /// The answer names a proposal revision that is not the current one.
    case staleProposal
    /// The ledger could not record the request's deadlines, so it was not
    /// sent.
    case ledgerUnavailable
}

/// Wall time and timers, injectable so tests run retries in milliseconds.
public struct PickAPlaceClock: Sendable {
    public let now: @Sendable () -> Date
    public let sleep: @Sendable (Duration) async throws -> Void

    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let system = PickAPlaceClock(now: { Date() }, sleep: { try await Task.sleep(for: $0) })
}

public struct PickAPlaceConfiguration: Hashable, Sendable {
    /// First wait before sending an unanswered step again. Doubles each time,
    /// up to `maxRetryInterval`. Delivery is best effort (ARCHITECTURE rule 5).
    public var retryInterval: Duration
    public var maxRetryInterval: Duration
    /// How long the organizer waits for friends' lists before choosing with
    /// the ones it has. A friend's phone may be waiting on its owner's
    /// consent sheet, so this is long.
    public var answerWindow: Duration
    /// How long the organizer waits for friends to say yes to a proposal;
    /// anyone who has not answered by then is left out.
    public var confirmWindow: Duration
    /// Live requests one friend may have open on this phone, and in total,
    /// so a friend cannot fill Home or keep the phone busy.
    public var maxLiveRequestsPerFriend: Int
    public var maxLiveRequests: Int
    /// Ended requests remembered so a late retry still gets the same reply.
    public var maxRememberedRequests: Int
    /// New requests one friend may start on this phone per hour, ended ones
    /// included, so a friend cannot probe the owner's limits with an
    /// endless stream of one-place requests (ADR 0230).
    public var maxNewRequestsPerFriendPerHour: Int
    /// Times the organizer repeats its confirmation to one friend who keeps
    /// saying yes, in case the confirmation was lost.
    public var maxConfirmationRepeats: Int

    public init(
        retryInterval: Duration = .seconds(5),
        maxRetryInterval: Duration = .seconds(60),
        answerWindow: Duration = .seconds(15 * 60),
        confirmWindow: Duration = .seconds(30 * 60),
        maxLiveRequestsPerFriend: Int = 4,
        maxLiveRequests: Int = 32,
        maxRememberedRequests: Int = 64,
        maxNewRequestsPerFriendPerHour: Int = 8,
        maxConfirmationRepeats: Int = 8
    ) {
        precondition(retryInterval > .zero && maxRetryInterval >= retryInterval && maxLiveRequestsPerFriend > 0)
        self.retryInterval = retryInterval
        self.maxRetryInterval = maxRetryInterval
        self.answerWindow = answerWindow
        self.confirmWindow = confirmWindow
        self.maxLiveRequestsPerFriend = maxLiveRequestsPerFriend
        self.maxLiveRequests = maxLiveRequests
        self.maxRememberedRequests = maxRememberedRequests
        self.maxNewRequestsPerFriendPerHour = maxNewRequestsPerFriendPerHour
        self.maxConfirmationRepeats = maxConfirmationRepeats
    }
}

/// The candidates the owner settled on in Compose, for `start(_:)`.
public protocol PlaceCandidateSource: Sendable {
    func candidates(for request: SkillRequest) async throws -> [PlaceCandidate]
}

/// Holds Compose's candidates until the coordinator calls `start(_:)`. The
/// app stages what `PlaceFinder` found, or what the owner typed, under the
/// interaction's ID; `start` takes them once.
public actor StagedCandidates: PlaceCandidateSource {
    private var staged: [InteractionID: [PlaceCandidate]] = [:]

    public init() {}

    public func stage(_ candidates: [PlaceCandidate], for interaction: InteractionID) {
        staged[interaction] = candidates
    }

    public func candidates(for request: SkillRequest) async throws -> [PlaceCandidate] {
        staged.removeValue(forKey: request.interaction) ?? []
    }
}

/// The Pick a place skill's runtime (ADR 0230).
///
/// As organizer it asks each friend which of the candidates fit, chooses the
/// venue that fits the most of them (`GroupChoice`), proposes it, and
/// confirms it with everyone who says yes. As a friend it judges the
/// candidates against its owner's private limits with facts it looks up
/// itself (`PlaceJudge`), and sends back only the ones that fit. Budget and
/// diet never leave the phone. Every send goes through the `Outbox`; every
/// receive comes from the app's Inbox loop through `handle(_:)`.
public actor PickAPlaceService: SkillService {
    public nonisolated let descriptor = PickAPlaceSkill.descriptor
    public nonisolated let events: AsyncStream<SkillEvent>
    let continuation: AsyncStream<SkillEvent>.Continuation

    let localPeer: PeerID
    let outbox: Outbox
    let pairedPeers: any PairedPeerStore
    let candidateSource: any PlaceCandidateSource
    let maps: any PlaceSearching
    let ownerLimits: @Sendable () async -> ConstraintSet
    let ledger: any PickAPlaceLedger
    /// The phone's one record of retired conversations and candidates
    /// answered (ADR 0021). The Outbox enforces it on every send; the
    /// service checks it before opening a request and before an ordinary
    /// no, and retires through `Outbox.retire(_:)`.
    let conversations: any ConversationLedger
    /// Whether `requestTimes` has been loaded from `admissions` this launch.
    var admissionsLoaded = false
    let clock: PickAPlaceClock
    let configuration: PickAPlaceConfiguration

    var cards: [PeerID: AgentCard] = [:]
    var organized: [ConversationID: Organizer] = [:]
    var invites: [ConversationID: Invite] = [:]
    var conversationOf: [InteractionID: ConversationID] = [:]
    /// Ended invites and organizers, oldest first, for pruning.
    var endedInvites: [ConversationID] = []
    var endedOrganizers: [ConversationID] = []
    /// Conversations whose retirement failed this launch: closed anyway.
    var unretired: Set<ConversationID> = []
    /// Yeses taken back, retried until the organizer acknowledges them.
    var pendingWithdrawals: [ConversationID: PendingWithdrawal] = [:]
    /// When each friend started requests on this phone, within the last hour.
    var requestTimes: [PeerID: [Date]] = [:]
    /// Cancels the work, sends included, still running for a conversation.
    /// Withdrawing or ending it cancels them, so a send suspended on a
    /// consent sheet or the policy recheck never leaves afterwards. Each
    /// entry removes itself when its work finishes.
    var tasks: [ConversationID: [UUID: Tracked]] = [:]

    /// One tracked piece of work. Asking work is cancelled on its own when
    /// the organizer stops asking.
    struct Tracked {
        let asking: Bool
        let cancel: @Sendable () -> Void
    }

    /// - Parameters:
    ///   - localPeer: This phone's ID, the Outbox's transport's `localPeer`.
    ///   - pairedPeers: Only these peers' requests are handled.
    ///   - candidates: Compose's candidates for `start(_:)`.
    ///   - maps: Looks up facts for venues friends suggest, by Maps
    ///     identifier, on this phone.
    ///   - ownerLimits: The owner's standing budget, diet, and place limits,
    ///     for requests from friends. The organizer's own limits come with
    ///     its `SkillIntent`.
    ///   - conversations: The `ConversationLedger` the app's Outbox enforces
    ///     (ADR 0021).
    ///   - ledger: What must survive a relaunch (`UserDefaultsPickAPlaceLedger`
    ///     in the app).
    public init(
        localPeer: PeerID,
        outbox: Outbox,
        pairedPeers: any PairedPeerStore,
        candidates: any PlaceCandidateSource,
        maps: any PlaceSearching,
        ownerLimits: @escaping @Sendable () async -> ConstraintSet,
        ledger: any PickAPlaceLedger,
        conversations: any ConversationLedger,
        clock: PickAPlaceClock = .system,
        configuration: PickAPlaceConfiguration = PickAPlaceConfiguration()
    ) {
        self.localPeer = localPeer
        self.outbox = outbox
        self.pairedPeers = pairedPeers
        candidateSource = candidates
        self.maps = maps
        self.ownerLimits = ownerLimits
        self.ledger = ledger
        self.conversations = conversations
        self.clock = clock
        self.configuration = configuration
        (events, continuation) = AsyncStream.makeStream(of: SkillEvent.self)
    }

    // MARK: - SkillService

    public func answer(_ interaction: InteractionID, with answer: OwnerAnswer) async throws {
        guard let conversation = conversationOf[interaction] else { throw PickAPlaceError.unknownInteraction }
        if organized[conversation] != nil {
            try await organizerAnswer(conversation, answer)
        } else if invites[conversation] != nil {
            try await inviteAnswer(conversation, answer)
        } else {
            throw PickAPlaceError.unknownInteraction
        }
    }

    public func withdraw(_ interaction: InteractionID) async {
        guard let conversation = conversationOf[interaction] else { return }
        if let organizer = organized[conversation] {
            if organizer.phase == .settled {
                callOff(conversation)
            } else {
                endOrganizer(conversation, event: .withdrawn, reason: .noOverlap)
            }
        } else if invites[conversation] != nil {
            leave(conversation, event: .withdrawn)
        }
    }

    /// Every event from the app's Inbox loop. Returns quickly: sends and
    /// lookups run on their own tasks, so a consent sheet never holds up
    /// the loop.
    public func handle(_ event: InboxEvent) async {
        guard case .message(let envelope) = event else { return }
        guard envelope.skill?.id == descriptor.id || envelope.body.kind == .hello else { return }
        // A skill envelope in a mode this skill does not offer is ignored
        // like any unknown request (ADR 0020, decision 5).
        if envelope.skill != nil {
            guard let mode = envelope.mode, descriptor.sendModes.contains(mode) else { return }
        }
        // Only paired friends. With the secure channel, the sender is
        // authenticated; the pairing store says whether it is a friend.
        guard (try? await pairedPeers.peer(for: envelope.sender)) != nil else { return }
        if case .hello(let card) = envelope.body {
            cards[envelope.sender] = card
            return
        }
        // Another major version fails closed on every envelope, not only
        // when a conversation opens: one already open at a compatible
        // version takes nothing from it either (issue #64). It gets no
        // reply: the organizer leaves such a friend out from its card, and
        // a reply per fresh conversation would let a friend make this phone
        // send without limit.
        guard let skill = envelope.skill, skill.version.isCompatible(with: descriptor.ref.version) else { return }

        let conversation = envelope.conversation
        // Any rejection from the organizer acknowledges a withdrawal: it
        // has left this phone out, or ended the request.
        if case .reject = envelope.body, pendingWithdrawals[conversation]?.organizer == envelope.sender {
            withdrawalAcknowledged(conversation)
        }
        if organized[conversation] != nil {
            organizerReceived(envelope)
        } else if invites[conversation] != nil {
            inviteReceived(envelope)
        } else if pendingWithdrawals[conversation] != nil || unretired.contains(conversation) {
            // Taken back, waiting for the organizer to hear it: nothing
            // reopens it.
            return
        } else {
            // A retired conversation is never opened again; a ledger that
            // cannot say opens nothing (ADR 0021).
            guard let retired = try? await conversations.isRetired(conversation), !retired else { return }
            await loadAdmissions()
            // Loading suspended: another message may have opened it.
            if invites[conversation] != nil {
                inviteReceived(envelope)
            } else if organized[conversation] == nil, pendingWithdrawals[conversation] == nil, admissionsLoaded {
                newInvite(envelope)
            }
        }
    }

    /// Ends `conversation` for good (ADR 0021) and only then says how it
    /// ended. Sends the goodbyes first, since retiring cancels sends in
    /// flight, then awaits `Outbox.retire(_:)`, so a crash can never leave a
    /// reported ending in a conversation still open to a new request. If
    /// the retirement fails, the ending is reported as `.failed`, never as
    /// a clean one, and the conversation stays closed for this launch
    /// (`unretired`). `event` nil reports nothing, as when the coordinator
    /// has already applied the owner's pass.
    func finish(_ conversation: ConversationID, interaction: InteractionID?, event: InteractionEvent?,
                goodbyes: [(PeerID, MessageBody)] = [], chainedFrom: ConversationID? = nil) {
        spawn(conversation) { service in
            for (peer, body) in goodbyes {
                await service.trySend(body, to: peer, conversation: conversation, chainedFrom: chainedFrom)
            }
            do {
                try await service.outbox.retire(conversation)
                if let interaction, let event { service.emit(interaction, event) }
            } catch {
                service.unretired.insert(conversation)
                if let interaction, event != nil { service.emit(interaction, .failed) }
            }
        }
    }

    /// Tells a friend its rejection was heard, with an ordinary no, so a
    /// withdrawal stops being retried. One reply per rejection received.
    func acknowledge(_ envelope: Envelope) {
        let (conversation, friend, chainedFrom) = (envelope.conversation, envelope.sender, envelope.chainedFrom)
        spawn(conversation) { service in
            await service.trySend(.reject(Rejection(proposal: envelope.id, reason: .noOverlap)), to: friend,
                                  conversation: conversation, chainedFrom: chainedFrom)
        }
    }

    /// Reads the admission log once per launch, before the first new
    /// request is admitted, and merges it with any admitted meanwhile.
    /// How long an admitted request holds a friend's slot: as long as an
    /// unanswered one can stay open (the answer window and three confirm
    /// windows), however it ended.
    var slotDuration: Duration { configuration.answerWindow + configuration.confirmWindow * 3 }

    func loadAdmissions() async {
        guard !admissionsLoaded else { return }
        // An unreadable ledger admits nothing: the limit must not reset.
        let since = clock.now().addingTimeInterval(-max(3_600, Self.seconds(slotDuration)))
        guard let stored = try? await ledger.admissions(since: since) else { return }
        guard !admissionsLoaded else { return }
        admissionsLoaded = true
        requestTimes.merge(stored) { current, loaded in Array(Set(current + loaded)).sorted() }
    }

    /// Ends every request silently and finishes `events`.
    public func shutdown() async {
        for list in tasks.values { list.values.forEach { $0.cancel() } }
        tasks = [:]
        organized = [:]
        invites = [:]
        conversationOf = [:]
        continuation.finish()
    }

    // MARK: - Shared helpers

    func emit(_ interaction: InteractionID, _ event: InteractionEvent) {
        continuation.yield(.lifecycle(interaction, event))
    }

    /// Sends one message of this skill through the Outbox, always as an
    /// invite (ADR 0020), naming the interaction it belongs to so the
    /// consent sheet and the audit find it. `answering` is the friend's
    /// query when the message only says which of its candidates work
    /// (ADR 0019); `accepting` is the friend's proposal when the message
    /// says yes to exactly its terms (ADR 0019, amendment 10).
    @discardableResult
    func send(_ body: MessageBody, to peer: PeerID, conversation: ConversationID, chainedFrom: ConversationID?,
              answering: Query? = nil, accepting: Proposal? = nil, interaction named: InteractionID? = nil) async throws -> Envelope {
        let interaction = named ?? organized[conversation]?.id ?? invites[conversation]?.id
        return try await outbox.send(body, to: peer, conversation: conversation, recipientCard: cards[peer],
                                     context: OutboundContext(answering: answering, interaction: interaction, accepting: accepting),
                                     skill: descriptor.ref, mode: descriptor.defaultSendMode, chainedFrom: chainedFrom)
    }

    /// A send whose failure changes nothing, such as a goodbye.
    func trySend(_ body: MessageBody, to peer: PeerID, conversation: ConversationID, chainedFrom: ConversationID?,
                 accepting: Proposal? = nil, interaction: InteractionID? = nil) async {
        _ = try? await send(body, to: peer, conversation: conversation, chainedFrom: chainedFrom, accepting: accepting, interaction: interaction)
    }

    /// Runs work for one conversation on its own task, cancelled when the
    /// conversation ends.
    func spawn(_ conversation: ConversationID, asking: Bool = false, _ work: @escaping @Sendable (isolated PickAPlaceService) async -> Void) {
        let token = UUID()
        let task = Task {
            await work(self)
            self.taskEnded(token, in: conversation)
        }
        tasks[conversation, default: [:]][token] = Tracked(asking: asking, cancel: { task.cancel() })
    }

    func taskEnded(_ token: UUID, in conversation: ConversationID) {
        tasks[conversation]?[token] = nil
        if tasks[conversation]?.isEmpty == true { tasks[conversation] = nil }
    }

    /// Runs a send on a tracked task and waits for it, so ending the
    /// conversation cancels it even while the caller is waiting.
    func trackedSend(_ body: MessageBody, to peer: PeerID, conversation: ConversationID, chainedFrom: ConversationID?,
                     accepting: Proposal? = nil) async -> (any Error)? {
        let task = Task { () -> (any Error)? in
            do {
                try await self.send(body, to: peer, conversation: conversation, chainedFrom: chainedFrom, accepting: accepting)
                return nil
            } catch {
                return error
            }
        }
        let token = UUID()
        tasks[conversation, default: [:]][token] = Tracked(asking: false, cancel: { task.cancel() })
        let result = await task.value
        taskEnded(token, in: conversation)
        return result
    }

    func cancelTasks(_ conversation: ConversationID) {
        tasks.removeValue(forKey: conversation)?.values.forEach { $0.cancel() }
    }

    /// Cancels only the organizer's queries, including one waiting on a
    /// consent sheet, once it has stopped asking.
    func cancelAsking(_ conversation: ConversationID) {
        guard let list = tasks[conversation] else { return }
        for (token, tracked) in list where tracked.asking {
            tracked.cancel()
            tasks[conversation]?[token] = nil
        }
    }

    /// Waits `interval`, then returns the next, doubled up to the maximum;
    /// nil if cancelled.
    func pause(_ interval: Duration) async -> Duration? {
        do { try await clock.sleep(interval) } catch { return nil }
        if Task.isCancelled { return nil }
        return min(interval * 2, configuration.maxRetryInterval)
    }

    /// Sleeps until `date`; false if cancelled.
    func sleep(until date: Date) async -> Bool {
        let seconds = max(0, date.timeIntervalSince(clock.now()))
        do { try await clock.sleep(.milliseconds(Int64(seconds * 1_000))) } catch { return false }
        return !Task.isCancelled
    }

    /// The plan the agreed place would make, when the terms say what or when.
    /// On a plan, the same plan at the new place, with its revision one
    /// higher and everyone still in it (ADR 0022).
    static func plan(base: Plan?, origin: ConversationID, roster: [PeerID], terms: Terms, place: PlaceChoice) -> Plan? {
        if let base { return try? base.updating(place: .some(place)) }
        guard let attendees = try? Attendees(roster) else { return nil }
        let activity: Keyword? = if case .keywords(let list)? = terms[.activity] { list.first } else { nil }
        let time: TimeSlot? = if case .slots(let list)? = terms[.time] { list.first } else { nil }
        return try? Plan(origin: origin, attendees: attendees, activity: activity, time: time, place: place)
    }
}
