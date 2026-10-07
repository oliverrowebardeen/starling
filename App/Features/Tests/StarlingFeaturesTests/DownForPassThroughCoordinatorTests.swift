import DownFor
import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import StarlingNegotiation
import Testing

/// Lane B's follow-up to PR #56 (P15-B request 9): a starter's pass on a
/// Down for... card through the real `LifecycleCoordinator` and the real
/// `DownForService` (ADR 0011 amendment 16, ADR 0210 decision 13). The
/// friend's agent is played on the wire, so everything the starter sends
/// it is recorded as it leaves. The service runs on virtual time, so every
/// deadline falls at an exact instant however busy the machine is
/// (lane F's #84).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct DownForPassThroughCoordinatorTests {
    /// The owner passes on the card, or never answers it. Either way the
    /// friend gets the same proposals at the same instants. A pass hides
    /// the card at once, changes and retires nothing until the window, and
    /// only then ends as passed, when silence ends as expired.
    @Test func aStartersPassLooksLikeSilenceToTheFriend() async throws {
        let passed = try await Self.starter(passes: true)
        let silent = try await Self.starter(passes: false)

        // Every scheduled proposal, at its instant, and nothing else.
        #expect(passed.sentByInstant == silent.sentByInstant)
        #expect(passed.sentByInstant == Array(1...Self.schedule.count))
        #expect(passed.kinds == [.propose] && silent.kinds == [.propose], "passed \(passed.kinds), silent \(silent.kinds)")

        #expect(passed.hiddenAtOnce)
        // Up to the window: still proposed, nothing retired, either way.
        #expect(passed.beforeWindow == .proposed && silent.beforeWindow == .proposed)
        #expect(!passed.retiredBeforeWindow && !silent.retiredBeforeWindow)
        // At the window: the pass, or the expiry, with the conversation retired.
        #expect(passed.ending == .ended(.declined) && silent.ending == .ended(.expired))
        #expect(passed.retiredAtEnd && silent.retiredAtEnd)
        #expect(!passed.stillHidden)
    }

    struct Outcome {
        /// Proposals the friend had received after each scheduled instant.
        let sentByInstant: [Int]
        /// Kinds the starter sent from its first proposal on, repeats collapsed.
        let kinds: [MessageBody.Kind]
        let hiddenAtOnce: Bool
        let beforeWindow: InteractionState?
        let retiredBeforeWindow: Bool
        let ending: InteractionState?
        let retiredAtEnd: Bool
        let stillHidden: Bool
    }

    static let window = Duration.seconds(2)
    static let retryInterval = Duration.milliseconds(20)
    static let maxBackoff = Duration.milliseconds(200)

    /// ADR 0210 decision 13: at once, then after waits that start at
    /// `retryInterval` and double up to `maxBackoff`, within the window.
    static var schedule: [Duration] {
        var schedule: [Duration] = [.zero]
        var wait = retryInterval
        while schedule.last! + wait <= window {
            schedule.append(schedule.last! + wait)
            wait = min(wait * 2, maxBackoff)
        }
        return schedule
    }

    static func starter(passes: Bool) async throws -> Outcome {
        // The starter's PeerID is the lowest, so it carries the pair.
        let me = try PeerID(bytes: Data(repeating: 0, count: 32))
        let friend = PeerID.random()
        let transport = RecordingTransport(localPeer: me)
        let ledger = InMemoryConversationLedger()
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved), ledger: ledger)
        let configuration = DownForConfiguration(retryInterval: retryInterval, maxAttempts: 100, ownerWindow: window, maxBackoff: maxBackoff)
        let time = VirtualTime()
        let service = DownForService(
            localPeer: me, outbox: outbox, model: ScriptedAgentModel(), psi: InsecurePSIStub(), ledger: ledger,
            clock: time.clock(now: Evening.now), timeZone: Evening.utc, configuration: configuration
        )
        let coordinator = LifecycleCoordinator(registry: try SkillRegistry([DownFor.descriptor]), services: [service], store: InMemoryInteractionStore(), now: { Evening.now })
        await coordinator.start()
        await service.handle(.peerAvailable(friend))

        let boba = try Keyword("boba")
        let rules = OwnerRules(constraints: try ConstraintSet([
            .time: [try Constraint(.within([try TimeSlot(start: Evening.at(19.5), end: Evening.at(21))]))],
            .activity: [try Constraint(.prefers(liked: [boba], avoided: []), strength: .soft)],
        ]))
        let conversation = ConversationID()
        let request = SkillRequest(
            interaction: InteractionID(), conversation: conversation,
            intent: SkillIntent(skill: DownFor.ref, rules: rules, audience: .picked([friend]), mode: .askQuietly, expiresAt: Timestamp(Evening.at(24))),
            participants: [friend]
        )
        let id = try await coordinator.start(request, settings: SkillSettings(flags: .phase1_5))

        // The friend's agent answers the time check and the activity query.
        let wire = FriendOnTheWire(me: me, friend: friend, transport: transport, service: service, conversation: conversation)
        try await wire.answerUntilProposed(liking: boba)
        try await until("the card") { coordinator.interaction(id)?.state == .proposed }
        // The whole schedule and the window are set from the moment of the
        // proposal, on virtual time that has not moved.
        let instants = Array(schedule.dropFirst()) + [window]
        try await until("the schedule") { Set(await time.due).isSuperset(of: instants) }
        func proposals() async -> Int { await wire.sentKinds().filter { $0 == .propose }.count }

        var hiddenAtOnce = false
        if passes {
            #expect(await coordinator.answer(id, with: .pass))
            hiddenAtOnce = coordinator.passed.contains(id)
        }

        var sentByInstant: [Int] = []
        try await until("the first proposal") { await proposals() == 1 }
        sentByInstant.append(await proposals())
        for (index, instant) in schedule.enumerated().dropFirst() {
            await time.advance(to: instant)
            try await until("proposal \(index + 1)") { await proposals() == index + 1 }
            sentByInstant.append(await proposals())
        }

        // Just before the window nothing is due: the card stands, unretired.
        await time.advance(to: window - .milliseconds(1))
        let beforeWindow = coordinator.interaction(id)?.state
        let retiredBeforeWindow = (try? await ledger.isRetired(conversation)) ?? true

        await time.advance(to: window)
        try await until("the ending") { coordinator.interaction(id)?.state.isFinal == true }
        #expect(await proposals() == schedule.count)

        let all = await wire.sentKinds()
        var kinds: [MessageBody.Kind] = []
        for kind in all.dropFirst(all.firstIndex(of: .propose) ?? 0) where kinds.last != kind { kinds.append(kind) }
        return Outcome(
            sentByInstant: sentByInstant, kinds: kinds, hiddenAtOnce: hiddenAtOnce,
            beforeWindow: beforeWindow, retiredBeforeWindow: retiredBeforeWindow,
            ending: coordinator.interaction(id)?.state,
            retiredAtEnd: (try? await ledger.isRetired(conversation)) ?? false, stillHidden: coordinator.passed.contains(id)
        )
    }

    /// Waits for `condition`, failing after 30 s of the host's awake time
    /// (`SuspendingClock`, ADR 0258). Only work already due is waited for;
    /// no deadline depends on it. The condition is checked once more at the
    /// deadline.
    static func until(_ what: String, _ condition: () async -> Bool) async throws {
        let clock = SuspendingClock()
        let deadline = clock.now + .seconds(30)
        while clock.now < deadline {
            if await condition() { return }
            try await clock.sleep(for: .milliseconds(5))
        }
        if await condition() { return }
        Issue.record("timed out waiting for \(what)")
        throw CancellationError()
    }
}

/// 2026-10-02, with `now` at 19:00 UTC on a 30-minute boundary.
enum Evening {
    static let now = Date(timeIntervalSince1970: 1_790_967_600)
    static let utc = TimeZone(identifier: "UTC")!
    static func at(_ hour: Double) -> Date { now.addingTimeInterval((hour - 19) * 3600) }
}

/// Plays the friend's agent: reads what the starter sent from the recording
/// transport and answers into the starter's service, as its Inbox would.
actor FriendOnTheWire {
    let me: PeerID
    let friend: PeerID
    let transport: RecordingTransport
    let service: DownForService
    let conversation: ConversationID
    private var sequence: UInt64 = 0

    init(me: PeerID, friend: PeerID, transport: RecordingTransport, service: DownForService, conversation: ConversationID) {
        self.me = me
        self.friend = friend
        self.transport = transport
        self.service = service
        self.conversation = conversation
    }

    func sent() async -> [Envelope] {
        await transport.sent.filter { $0.peer == friend }.compactMap { try? EnvelopeCodec().decode($0.frame.bytes) }
    }

    func sentKinds() async -> [MessageBody.Kind] { await sent().map(\.body.kind) }

    /// The first envelope of `kind` sent to the friend, waiting up to 30 s of
    /// the host's awake time for it.
    private func next(_ kind: MessageBody.Kind) async throws -> Envelope {
        let clock = SuspendingClock()
        let deadline = clock.now + .seconds(30)
        while clock.now < deadline {
            if let envelope = await sent().first(where: { $0.body.kind == kind }) { return envelope }
            try await clock.sleep(for: .milliseconds(1))
        }
        if let envelope = await sent().first(where: { $0.body.kind == kind }) { return envelope }
        throw ValidationError("FriendOnTheWire", "no \(kind.rawValue)")
    }

    private func reply(_ body: MessageBody) async throws {
        sequence += 1
        let envelope = try Envelope(
            conversation: conversation, sender: friend, recipient: me, sequence: sequence, sentAt: Timestamp(Evening.now),
            body: body, skill: DownFor.ref, mode: .askQuietly
        )
        await service.handle(.message(envelope))
    }

    /// Answers the starter's time check over the whole evening and says yes
    /// to `liked`, then waits for the proposal.
    func answerUntilProposed(liking liked: Keyword) async throws {
        let first = try await next(.psi)
        guard case .psi(let frame) = first.body else { return }
        let tokens = SlotTokenSet(
            namespace: "down_for/v1", constraints: .empty, now: Evening.now,
            expiresAt: Evening.at(24), timeZone: Evening.utc
        )
        let session = try InsecurePSIStub().makeSession(role: .responder, localSet: tokens.elements, configuration: SlotTokenSet.psiConfiguration())
        switch try await session.handle(frame.payload) {
        case .send(let payload), .finish(let payload?, _):
            try await reply(.psi(try PSIFrame(session: frame.session, step: frame.step + 1, payload: payload)))
        default:
            throw ValidationError("FriendOnTheWire", "no PSI reply")
        }
        let query = try await next(.query)
        try await reply(.answer(try Answer(query: query.id, issue: .activity, status: .answered, acceptable: .keywords([liked]))))
        _ = try await next(.propose)
    }
}

/// Virtual time for the service's clock: a sleep returns only when the test
/// advances past its deadline. Wall time stays at the date given to
/// `clock(now:)`.
actor VirtualTime {
    private(set) var now: Duration = .zero
    private var sleepers: [UUID: (at: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]

    /// When each pending sleep is due, earliest first.
    var due: [Duration] { sleepers.values.map(\.at).sorted() }

    nonisolated func clock(now date: Date) -> SkillClock {
        SkillClock(now: { date }, sleep: { try await self.sleep($0) })
    }

    func sleep(_ duration: Duration) async throws {
        guard duration > .zero else { return }
        let id = UUID()
        let at = now + duration
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = (at, continuation)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    /// Moves time forward to `time`, waking every sleep due by then.
    func advance(to time: Duration) {
        now = max(now, time)
        for (id, sleeper) in sleepers.sorted(by: { $0.value.at < $1.value.at }) where sleeper.at <= now {
            sleepers[id] = nil
            sleeper.continuation.resume()
        }
    }
}
