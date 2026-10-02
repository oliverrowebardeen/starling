import Foundation
import StarlingCore
import StarlingFakes
import Testing

/// ADR 0021: the ledger Outbox enforces for every skill.
@Suite struct ConversationLedgerTests {
    static func keywords(_ words: Range<Int>) -> IssueValue {
        .keywords(words.map { try! Keyword("k\($0)") })
    }

    static func answerBody(_ query: Query, yes: IssueValue) throws -> MessageBody {
        .answer(try Answer(query: MessageID(), issue: query.issue, status: .answered, acceptable: yes))
    }

    func outbox(_ ledger: InMemoryConversationLedger, transport: RecordingTransport, observer: RecordingOutboxObserver? = nil) -> Outbox {
        Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
               observer: observer, ledger: ledger, now: { Fixtures.now })
    }

    @Test func anAnswerReservesWhatItCoversAndStopsAtTheLimit() async throws {
        let ledger = InMemoryConversationLedger()
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let outbox = outbox(ledger, transport: transport)
        let first = try Query(issue: .activity, candidates: Self.keywords(0..<10))
        try await outbox.send(Self.answerBody(first, yes: Self.keywords(0..<1)), to: Fixtures.bob, conversation: Fixtures.conversation,
                              context: OutboundContext(answering: first))
        // Asking again about the same candidates costs nothing.
        try await outbox.send(Self.answerBody(first, yes: Self.keywords(0..<1)), to: Fixtures.bob, conversation: Fixtures.conversation,
                              context: OutboundContext(answering: first))
        #expect(await ledger.answeredCount(issue: .activity, to: Fixtures.bob, in: Fixtures.conversation) == 10)
        // Ten more distinct candidates would make twenty: refused, nothing sent.
        let second = try Query(issue: .activity, candidates: Self.keywords(10..<20))
        await #expect(throws: OutboxError.answerLimitReached) {
            try await outbox.send(Self.answerBody(second, yes: Self.keywords(10..<11)), to: Fixtures.bob, conversation: Fixtures.conversation,
                                  context: OutboundContext(answering: second))
        }
        #expect(await transport.sent.count == 2)
        // Another conversation, or another friend, has its own budget.
        try await outbox.send(Self.answerBody(second, yes: Self.keywords(10..<11)), to: Fixtures.bob, conversation: ConversationID(),
                              context: OutboundContext(answering: second))
        #expect(await transport.sent.count == 3)
    }

    @Test func nothingLeavesInARetiredConversationAndAFailingLedgerStopsTheSend() async throws {
        let ledger = InMemoryConversationLedger()
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let outbox = outbox(ledger, transport: transport)
        let body = MessageBody.reject(Rejection(proposal: MessageID(), reason: .noOverlap))
        try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
        try await ledger.retire(Fixtures.conversation)
        await #expect(throws: OutboxError.conversationRetired) {
            try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
        }
        await ledger.failAll()
        await #expect(throws: InMemoryConversationLedger.Unavailable.self) {
            try await outbox.send(body, to: Fixtures.bob, conversation: ConversationID())
        }
        #expect(await transport.sent.count == 1)
    }

    /// Review of PR #51: the audit heard about a send only after it left, so
    /// a crash in between lost it. willSend comes first and can stop it.
    @Test func theObserverHearsBeforeAnythingLeavesAndCanStopIt() async throws {
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let observer = RecordingOutboxObserver()
        let outbox = outbox(InMemoryConversationLedger(), transport: transport, observer: observer)
        let body = MessageBody.reject(Rejection(proposal: MessageID(), reason: .noOverlap))
        let sent = try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
        #expect(await observer.announced == [sent.id])
        #expect(await observer.records.map(\.envelope.id) == [sent.id])
        await observer.refuseNextSends()
        await #expect(throws: RecordingOutboxObserver.Refused.self) {
            try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
        }
        #expect(await transport.sent.count == 1)
    }

    @Test func listValuesSplitIntoSingleCandidates() throws {
        let value = Self.keywords(0..<3)
        #expect(value.candidates == [Self.keywords(0..<1), Self.keywords(1..<2), Self.keywords(2..<3)])
        let amount = IssueValue.amount(try MoneyAmount(minorUnits: 500))
        #expect(amount.candidates == [amount])
    }
}

/// Review of PR #60: the second round of checks around numbering and the ledger.
@Suite struct OutboxAdmissionTests {
    static let carol = try! PeerID(bytes: Data(repeating: 0xCC, count: 32))
    static let start = UInt64(Fixtures.now.timeIntervalSince1970 * 1000)
    static let body = MessageBody.reject(Rejection(proposal: MessageID(), reason: .noOverlap))

    @Test func everyAnswerNamesItsQueryAndReservesWhatItReturns() async throws {
        let ledger = InMemoryConversationLedger()
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                            ledger: ledger, now: { Fixtures.now })
        let yes = try Answer(query: MessageID(), issue: .activity, status: .answered, acceptable: ConversationLedgerTests.keywords(0..<10))
        await #expect(throws: OutboxError.answerWithoutItsQuery) {
            try await outbox.send(.answer(yes), to: Fixtures.bob, conversation: Fixtures.conversation)
        }
        let otherIssue = try Query(issue: .time, candidates: .slots([try TimeSlot(startMinute: 0, endMinute: 30)]))
        await #expect(throws: OutboxError.answerWithoutItsQuery) {
            try await outbox.send(.answer(yes), to: Fixtures.bob, conversation: Fixtures.conversation, context: OutboundContext(answering: otherIssue))
        }
        // A one-candidate query answered with seventeen values reserves all
        // seventeen, which is past the limit.
        func slots(_ count: Int64) throws -> IssueValue { .slots(try (0..<count).map { try TimeSlot(startMinute: $0 * 60, endMinute: $0 * 60 + 30) }) }
        let narrow = try Query(issue: .time, candidates: try slots(1))
        let wide = try Answer(query: MessageID(), issue: .time, status: .answered, acceptable: try slots(17))
        await #expect(throws: OutboxError.answerLimitReached) {
            try await outbox.send(.answer(wide), to: Fixtures.bob, conversation: Fixtures.conversation, context: OutboundContext(answering: narrow))
        }
        #expect(await transport.sent.isEmpty)
    }

    @Test func numbersRunPerFriendSoNobodySeesTrafficToOthers() async throws {
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved), now: { Fixtures.now })
        let toBob = try await outbox.send(Self.body, to: Fixtures.bob, conversation: Fixtures.conversation)
        let toCarol = try await outbox.send(Self.body, to: Self.carol, conversation: Fixtures.conversation)
        let toBobAgain = try await outbox.send(Self.body, to: Fixtures.bob, conversation: Fixtures.conversation)
        #expect([toBob.sequence, toCarol.sequence, toBobAgain.sequence] == [Self.start, Self.start, Self.start + 1])
    }

    @Test func aSendCancelledWhileQueuedTakesNoNumber() async throws {
        let transport = StallingTransport(localPeer: Fixtures.alice)
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved), now: { Fixtures.now })
        await transport.stallNext()
        let first = Task { try await outbox.send(Self.body, to: Fixtures.bob, conversation: Fixtures.conversation) }
        try await waitUntil { await transport.stalled }
        let queued = Task { try await outbox.send(Self.body, to: Fixtures.bob, conversation: Fixtures.conversation) }
        try await Task.sleep(for: .milliseconds(50))
        queued.cancel()
        await transport.release()
        _ = try await first.value
        await #expect(throws: CancellationError.self) { try await queued.value }
        let third = try await outbox.send(Self.body, to: Fixtures.bob, conversation: Fixtures.conversation)
        #expect(await transport.sentSequences == [Self.start, Self.start + 1])
        #expect(third.sequence == Self.start + 1)
    }

    @Test func aTransportThatDropsACancelledSendGivesTheNumberBack() async throws {
        let transport = StallingTransport(localPeer: Fixtures.alice)
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved), now: { Fixtures.now })
        await transport.cancelNext()
        await #expect(throws: CancellationError.self) {
            try await outbox.send(Self.body, to: Fixtures.bob, conversation: Fixtures.conversation)
        }
        let next = try await outbox.send(Self.body, to: Fixtures.bob, conversation: Fixtures.conversation)
        #expect(next.sequence == Self.start)
    }

    @Test func aConversationRetiredWhileASendWaitsStopsIt() async throws {
        let ledger = InMemoryConversationLedger()
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let observer = GatedObserver()
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                            observer: observer, ledger: ledger, now: { Fixtures.now })
        let send = Task { try await outbox.send(Self.body, to: Fixtures.bob, conversation: Fixtures.conversation) }
        try await waitUntil { await observer.waiting }
        try await ledger.retire(Fixtures.conversation)
        await observer.release()
        await #expect(throws: OutboxError.conversationRetired) { try await send.value }
        #expect(await transport.sent.isEmpty)
    }

    /// Re-review of PR #60: a send cleared before retirement and waiting in
    /// the transport's own queue (behind another conversation's stalled
    /// send) must not leave once the conversation is retired.
    @Test func retiringCancelsASendWaitingInTheTransportsQueue() async throws {
        let ledger = InMemoryConversationLedger()
        let transport = SerialStallingTransport(localPeer: Fixtures.alice)
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                            ledger: ledger, now: { Fixtures.now })
        let other = ConversationID()
        await transport.stall()
        let blocking = Task { try await outbox.send(Self.body, to: Fixtures.bob, conversation: other) }
        try await waitUntil { await transport.waiting == 1 }
        let doomed = Task { try await outbox.send(Self.body, to: Fixtures.bob, conversation: Fixtures.conversation) }
        try await waitUntil { await transport.waiting == 2 }
        try await outbox.retire(Fixtures.conversation)
        await transport.release()
        _ = try await blocking.value
        await #expect(throws: CancellationError.self) { try await doomed.value }
        #expect(await transport.delivered == [other])
        await #expect(throws: OutboxError.conversationRetired) {
            try await outbox.send(Self.body, to: Fixtures.bob, conversation: Fixtures.conversation)
        }
    }

    func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out")
    }
}

/// Holds one send until released, or drops one as cancelled.
actor StallingTransport: Transport {
    nonisolated let kind = TransportKind.loopback
    nonisolated let localPeer: PeerID
    nonisolated let events: AsyncStream<TransportEvent>
    private(set) var sentSequences: [UInt64] = []
    private(set) var stalled = false
    private var stallArmed = false
    private var cancelArmed = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(localPeer: PeerID) {
        self.localPeer = localPeer
        events = AsyncStream { _ in }
    }

    func stallNext() { stallArmed = true }
    func cancelNext() { cancelArmed = true }
    func release() { waiter?.resume(); waiter = nil; stalled = false }
    func start() async throws {}
    func stop() async {}

    func send(_ frame: Frame, to peer: PeerID) async throws {
        if cancelArmed { cancelArmed = false; throw CancellationError() }
        if stallArmed {
            stallArmed = false
            stalled = true
            await withCheckedContinuation { waiter = $0 }
        }
        sentSequences.append(try EnvelopeCodec().decode(frame.bytes).sequence)
    }
}

/// Holds willSend until released.
actor GatedObserver: OutboxObserver {
    private(set) var waiting = false
    private var gate: CheckedContinuation<Void, Never>?

    func release() { gate?.resume(); gate = nil }

    func outbox(willSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async throws {
        waiting = true
        await withCheckedContinuation { gate = $0 }
    }

    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {}
}

/// One queue for every send, like SecureTransport: while stalled, sends
/// wait in order; a send cancelled while waiting is dropped before it goes.
actor SerialStallingTransport: Transport {
    nonisolated let kind = TransportKind.loopback
    nonisolated let localPeer: PeerID
    nonisolated let events: AsyncStream<TransportEvent>
    private(set) var delivered: [ConversationID] = []
    private(set) var waiting = 0
    private var stalled = false
    private var gates: [CheckedContinuation<Void, Never>] = []

    init(localPeer: PeerID) {
        self.localPeer = localPeer
        events = AsyncStream { _ in }
    }

    func stall() { stalled = true }
    func release() { stalled = false; for gate in gates { gate.resume() }; gates = [] }
    func start() async throws {}
    func stop() async {}

    func send(_ frame: Frame, to peer: PeerID) async throws {
        if stalled {
            waiting += 1
            await withCheckedContinuation { gates.append($0) }
        }
        try Task.checkCancellation()
        delivered.append(try EnvelopeCodec().decode(frame.bytes).conversation)
    }
}

/// Review of lane A's PR #54: a stricter setting or a failed retirement must
/// stop sends cleared earlier and still waiting.
@Suite struct RevocationTests {
    static let body = MessageBody.reject(Rejection(proposal: MessageID(), reason: .noOverlap))

    @Test func aStricterPolicyStopsASendThatWasClearedAndIsWaiting() async throws {
        let policy = SwitchablePolicy(.allow)
        let transport = StallingTransport(localPeer: Fixtures.alice)
        let outbox = Outbox(transport: transport, policy: policy, consent: ScriptedConsentProvider(.approved), now: { Fixtures.now })
        await transport.stallNext()
        let first = Task { try await outbox.send(Self.body, to: Fixtures.bob, conversation: Fixtures.conversation) }
        try await OutboxAdmissionTests().waitUntil { await transport.stalled }
        let waiting = Task { try await outbox.send(Self.body, to: Fixtures.bob, conversation: Fixtures.conversation) }
        try await Task.sleep(for: .milliseconds(50))
        let violation = PolicyViolation(rule: "never", issue: .place)
        await policy.set(.deny(violation))
        await transport.release()
        _ = try await first.value
        await #expect(throws: OutboxError.denied(violation)) { try await waiting.value }
        #expect(await transport.sentSequences.count == 1)
    }

    @Test func cancelInFlightStopsEverySendStillWaiting() async throws {
        let transport = SerialStallingTransport(localPeer: Fixtures.alice)
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved), now: { Fixtures.now })
        await transport.stall()
        let sends = (0..<3).map { _ in Task { try await outbox.send(Self.body, to: Fixtures.bob, conversation: ConversationID()) } }
        try await OutboxAdmissionTests().waitUntil { await transport.waiting == 3 }
        await outbox.cancelInFlight()
        await transport.release()
        for send in sends { await #expect(throws: CancellationError.self) { try await send.value } }
        #expect(await transport.delivered.isEmpty)
    }

    @Test func aRetirementTheLedgerCannotRecordStillStopsSendsInFlight() async throws {
        let ledger = InMemoryConversationLedger()
        let transport = SerialStallingTransport(localPeer: Fixtures.alice)
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                            ledger: ledger, now: { Fixtures.now })
        await transport.stall()
        let send = Task { try await outbox.send(Self.body, to: Fixtures.bob, conversation: Fixtures.conversation) }
        try await OutboxAdmissionTests().waitUntil { await transport.waiting == 1 }
        await ledger.failAll()
        await #expect(throws: InMemoryConversationLedger.Unavailable.self) { try await outbox.retire(Fixtures.conversation) }
        await transport.release()
        await #expect(throws: CancellationError.self) { try await send.value }
        #expect(await transport.delivered.isEmpty)
    }
}

/// A policy a test can tighten.
actor SwitchablePolicy: PolicyEngine {
    private var decision: PolicyDecision
    init(_ decision: PolicyDecision) { self.decision = decision }
    func set(_ decision: PolicyDecision) { self.decision = decision }
    func evaluate(_ message: OutboundMessage) async -> PolicyDecision { decision }
}

/// Issue #81 (lane F): cancelInFlight() and retire(_:) must reach a send
/// still waiting on its consent sheet or in willSend, not only one queued
/// for the transport.
@Suite struct CancelEverywhereTests {
    static let body = MessageBody.reject(Rejection(proposal: MessageID(), reason: .noOverlap))

    @Test func cancelInFlightReachesASendWaitingOnItsConsentSheet() async throws {
        let consent = HeldConsent()
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let disclosure = Disclosure(recipient: Fixtures.bob, recipientModel: .onDevice, items: [])
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.needsConsent(disclosure)), consent: consent, now: { Fixtures.now })
        let send = Task { try await outbox.send(Self.body, to: Fixtures.bob, conversation: Fixtures.conversation) }
        try await OutboxAdmissionTests().waitUntil { await consent.asked }
        await outbox.cancelInFlight()
        await #expect(throws: (any Error).self) { try await send.value }
        #expect(await consent.sawCancellation)
        #expect(await transport.sent.isEmpty)
    }

    @Test func retireReachesASendWaitingInWillSend() async throws {
        let ledger = InMemoryConversationLedger()
        let observer = GatedObserver()
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                            observer: observer, ledger: ledger, now: { Fixtures.now })
        let send = Task { try await outbox.send(Self.body, to: Fixtures.bob, conversation: Fixtures.conversation) }
        try await OutboxAdmissionTests().waitUntil { await observer.waiting }
        try await outbox.retire(Fixtures.conversation)
        await observer.release()
        await #expect(throws: (any Error).self) { try await send.value }
        #expect(await transport.sent.isEmpty)
    }
}

/// A consent sheet that stays open until its send is cancelled, and notes
/// that it saw the cancellation (the app closes the sheet then).
actor HeldConsent: ConsentProvider {
    private(set) var asked = false
    private(set) var sawCancellation = false
    private var pending: CheckedContinuation<ConsentOutcome, Never>?

    func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        asked = true
        return await withTaskCancellationHandler {
            await withCheckedContinuation { pending = $0 }
        } onCancel: {
            Task { await self.cancelled() }
        }
    }

    private func cancelled() {
        sawCancellation = true
        pending?.resume(returning: .declined)
        pending = nil
    }
}
