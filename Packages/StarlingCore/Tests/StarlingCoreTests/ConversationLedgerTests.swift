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
