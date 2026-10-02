import Foundation
import StarlingCore
import StarlingFakes
import StarlingPolicy
import Testing

@Suite(.timeLimit(.minutes(5))) struct ConversationLedgerAttackTests {
    enum Shape: CaseIterable, Sendable {
        case keywords, slots, places, peers, amount, count, flag

        func candidate(_ index: Int) throws -> IssueValue {
            switch self {
            case .keywords: .keywords([try Keyword("option \(index)")])
            case .slots: .slots([try TimeSlot(startMinute: Int64(index * 60), endMinute: Int64(index * 60 + 30))])
            case .places: .places([try PlaceChoice(name: PlaceName("Same Cafe"), coordinate: Coordinate(latitude: Double(index), longitude: 1))])
            case .peers: .peers([try PeerID(bytes: Data(repeating: UInt8(index + 1), count: 32))])
            case .amount: .amount(try MoneyAmount(minorUnits: Int64(index * 100)))
            case .count: .count(index)
            case .flag: .flag(index % 2 == 0)
            }
        }
    }

    static func answer(_ value: IssueValue, issue: IssueKey = .interests) throws -> MessageBody {
        .answer(try Answer(query: MessageID(), issue: issue, status: .answered, acceptable: value))
    }

    static func box(_ wire: RecordingTransport, _ ledger: any ConversationLedger,
                    observer: (any OutboxObserver)? = nil, sequences: (any SentSequenceStore)? = nil) -> Outbox {
        Outbox(transport: wire, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
               observer: observer, sequences: sequences, ledger: ledger, now: { P15.date })
    }

    @Test(arguments: Shape.allCases)
    func replacementAndSkillChangesCannotRefillDistinctCandidateBudget(shape: Shape) async throws {
        let ledger = InMemoryConversationLedger()
        let wire = RecordingTransport(localPeer: P15.alice)
        let store = InMemorySentSequenceStore()
        let observer = RecordingOutboxObserver()
        let conversation = ConversationID()
        var outbox = Self.box(wire, ledger, observer: observer, sequences: store)
        let distinct = shape == .flag ? 2 : 16
        for index in 0..<distinct {
            if index == distinct / 2 { outbox = Self.box(wire, ledger, observer: observer, sequences: store) }
            let value = try shape.candidate(index)
            let query = try Query(issue: .interests, candidates: value)
            let skill = SampleSkills.all[index % SampleSkills.all.count]
            try await outbox.send(Self.answer(value), to: P15.bob, conversation: conversation,
                context: OutboundContext(answering: query), skill: skill.ref, mode: skill.defaultSendMode,
                chainedFrom: ConversationID())
        }
        #expect(await ledger.answeredCount(issue: .interests, to: P15.bob, in: conversation) == distinct)
        let before = try #require(store.highestSent(in: conversation, to: P15.bob))
        if shape != .flag {
            let seventeenth = try shape.candidate(16)
            await #expect(throws: OutboxError.answerLimitReached) {
                try await outbox.send(Self.answer(seventeenth), to: P15.bob, conversation: conversation,
                    context: OutboundContext(answering: Query(issue: .interests, candidates: seventeenth)))
            }
            #expect(store.highestSent(in: conversation, to: P15.bob) == before)
            #expect(await observer.announced.count == distinct)
        }
        // A fresh query ID and a codec round trip of an old candidate cost nothing.
        let old = try JSONDecoder().decode(IssueValue.self, from: JSONEncoder().encode(shape.candidate(0)))
        let repeated = try await outbox.send(Self.answer(old), to: P15.bob, conversation: conversation,
            context: OutboundContext(answering: Query(issue: .interests, candidates: old)))
        #expect(repeated.sequence == before + 1)
        #expect(await ledger.answeredCount(issue: .interests, to: P15.bob, in: conversation) == distinct)
        // Friend, issue, and conversation are three independent scopes.
        for (peer, scope, issue) in [(P15.eve, conversation, IssueKey.interests),
                                    (P15.bob, ConversationID(), .interests), (P15.bob, conversation, .diet)] {
            let value = try shape.candidate(16)
            try await outbox.send(Self.answer(value, issue: issue), to: peer, conversation: scope,
                context: OutboundContext(answering: Query(issue: issue, candidates: value)))
            #expect(await ledger.answeredCount(issue: issue, to: peer, in: scope) == 1)
        }
    }

    @Test func queryAndReturnedCandidatesBothCountAndOversizedReservationsAreAtomic() async throws {
        let ledger = InMemoryConversationLedger()
        let wire = RecordingTransport(localPeer: P15.alice)
        let observer = RecordingOutboxObserver()
        let sequences = InMemorySentSequenceStore()
        let outbox = Self.box(wire, ledger, observer: observer, sequences: sequences)
        let conversation = ConversationID()
        func slots(_ range: Range<Int>) throws -> IssueValue {
            .slots(try range.map { try TimeSlot(startMinute: Int64($0 * 60), endMinute: Int64($0 * 60 + 30)) })
        }
        func send(_ query: IssueValue, _ returned: IssueValue) async throws -> Envelope {
            try await outbox.send(Self.answer(returned), to: P15.bob, conversation: conversation,
                context: OutboundContext(answering: Query(issue: .interests, candidates: query)))
        }
        // Empty yes sets still answer every candidate. The policy is scripted
        // here so added values exercise the ledger independently of topic rules.
        let first = try await send(slots(0..<8), .slots([]))
        #expect(await ledger.answeredCount(issue: .interests, to: P15.bob, in: conversation) == 8)
        await #expect(throws: OutboxError.answerLimitReached) { try await send(slots(8..<16), slots(16..<17)) }
        #expect(await ledger.answeredCount(issue: .interests, to: P15.bob, in: conversation) == 8)
        #expect(sequences.highestSent(in: conversation, to: P15.bob) == first.sequence)
        #expect(await observer.announced.count == 1)
        let second = try await send(slots(8..<12), slots(12..<16))
        #expect(second.sequence == first.sequence + 1)
        #expect(await ledger.answeredCount(issue: .interests, to: P15.bob, in: conversation) == 16)
        await #expect(throws: OutboxError.answerLimitReached) { try await send(slots(0..<1), slots(16..<17)) }
        #expect(await wire.sent.count == 2)
        #expect(await observer.records.count == 2)
    }

    @Test func everyValuedAnswerNeedsSameIssueContextButADeclinedAnswerHasNoValues() async throws {
        let ledger = InMemoryConversationLedger()
        let wire = RecordingTransport(localPeer: P15.alice)
        let observer = RecordingOutboxObserver()
        let sequences = InMemorySentSequenceStore()
        let outbox = Self.box(wire, ledger, observer: observer, sequences: sequences)
        let conversation = ConversationID()
        for shape in Shape.allCases {
            let value = try shape.candidate(0)
            for context in [OutboundContext.empty, OutboundContext(answering: try Query(issue: .diet, candidates: value))] {
                await #expect(throws: OutboxError.answerWithoutItsQuery) {
                    try await outbox.send(Self.answer(value), to: P15.bob, conversation: conversation, context: context)
                }
            }
        }
        #expect(await ledger.answeredCount(issue: .interests, to: P15.bob, in: conversation) == 0)
        #expect(sequences.highestSent(in: conversation, to: P15.bob) == nil)
        #expect(await observer.announced.isEmpty)
        #expect(await wire.sent.isEmpty)
        for status in [Answer.Status.declined, .pendingOwner] {
            try await outbox.send(.answer(Answer(query: MessageID(), issue: .interests, status: status)),
                                  to: P15.bob, conversation: conversation)
        }
        #expect(await wire.sent.count == 2)
        #expect(await ledger.answeredCount(issue: .interests, to: P15.bob, in: conversation) == 0)
    }

    @Test func concurrentAnswersCannotRacePastSixteen() async throws {
        let ledger = InMemoryConversationLedger()
        let wire = RecordingTransport(localPeer: P15.alice)
        let outbox = Self.box(wire, ledger)
        let conversation = ConversationID()
        let results = try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let value = IssueValue.count(index)
                    do {
                        try await outbox.send(Self.answer(value), to: P15.bob, conversation: conversation,
                            context: OutboundContext(answering: Query(issue: .interests, candidates: value)))
                        return true
                    } catch OutboxError.answerLimitReached { return false }
                }
            }
            var outcomes: [Bool] = []
            for try await result in group { outcomes.append(result) }
            return outcomes
        }
        #expect(results.filter { $0 }.count == 16)
        #expect(results.filter { !$0 }.count == 8)
        #expect(await wire.sent.count == 16)
        #expect(await ledger.answeredCount(issue: .interests, to: P15.bob, in: conversation) == 16)
        let numbers = try await wire.sent.map { try EnvelopeCodec().decode($0.frame.bytes).sequence }
        #expect(zip(numbers, numbers.dropFirst()).allSatisfy { $1 == $0 + 1 })
    }

    @Test func policyDenialAndDeclinedConsentCannotSpendTheCandidateBudget() async throws {
        for choice in [SharingChoice.never, .askMe] {
            let ledger = InMemoryConversationLedger()
            let wire = RecordingTransport(localPeer: P15.alice)
            let observer = RecordingOutboxObserver()
            let sequences = InMemorySentSequenceStore()
            let friend = try PairedPeer(publicKey: IdentityPublicKey(hex: String(repeating: "bb", count: 32)), nickname: "Sam", pairedAt: P15.now)
            let privacy = try PrivacySettings([.interests: choice])
            let engine = DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty, disclosure: privacy.disclosureRules),
                                                  pairedPeers: InMemoryPairedPeerStore([friend]))
            let consent = ScriptedConsentProvider(.declined)
            let outbox = Outbox(transport: wire, policy: engine, consent: consent, observer: observer,
                                sequences: sequences, ledger: ledger, now: { P15.date })
            let conversation = ConversationID()
            let candidates = IssueValue.keywords(try (0..<16).map { try Keyword("option \($0)") })
            let query = try Query(issue: .interests, candidates: candidates)
            let added = IssueValue.keywords([try Keyword("private interest")])
            let expected = choice == .never ? OutboxError.denied(PolicyViolation(rule: PolicyRuleID.never, issue: .interests)) : .consentDeclined
            await #expect(throws: expected) {
                try await outbox.send(Self.answer(added), to: friend.id, conversation: conversation,
                    recipientCard: P15.card([SampleSkills.downFor.ref]), context: OutboundContext(answering: query))
            }
            #expect(await ledger.answeredCount(issue: .interests, to: friend.id, in: conversation) == 0)
            #expect(sequences.highestSent(in: conversation, to: friend.id) == nil)
            #expect(await observer.announced.isEmpty)
            #expect(await wire.sent.isEmpty)
            try await outbox.send(Self.answer(.keywords([])), to: friend.id, conversation: conversation,
                recipientCard: P15.card([SampleSkills.downFor.ref]), context: OutboundContext(answering: query))
            #expect(await ledger.answeredCount(issue: .interests, to: friend.id, in: conversation) == 16)
            #expect(await wire.sent.count == 1)
            #expect(await consent.requests.count == (choice == .askMe ? 1 : 0))
        }
    }

    @Test func retiredIDsSurviveChurnElapsedDaysAndReplacementForEveryMessageKind() async throws {
        let ledger = InMemoryConversationLedger()
        let wire = RecordingTransport(localPeer: P15.alice)
        let outbox = Self.box(wire, ledger)
        let old = ConversationID()
        try await outbox.retire(old)
        for _ in 0..<300 { try await outbox.retire(ConversationID()) }
        let observer = RecordingOutboxObserver()
        let relaunched = Outbox(transport: wire, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
            observer: observer, ledger: ledger, now: { P15.date.addingTimeInterval(172_800) })
        let bodies = try P15.bodies(issue: .place, value: P15.value(.place)) + [
            .hello(P15.card(SampleSkills.all.map(\.ref))),
            .reject(Rejection(proposal: MessageID(), reason: .noOverlap)),
            .psi(PSIFrame(session: UUID(), step: 0, payload: Data())),
        ]
        for skill in SampleSkills.all {
            for body in bodies {
                await #expect(throws: OutboxError.conversationRetired) {
                    try await relaunched.send(body, to: P15.bob, conversation: old,
                        skill: skill.ref, mode: skill.defaultSendMode, chainedFrom: ConversationID())
                }
            }
        }
        #expect(try await ledger.isRetired(old))
        #expect(await wire.sent.isEmpty)
        #expect(await observer.announced.isEmpty)
        let fresh = ConversationID()
        try await relaunched.send(.reject(Rejection(proposal: MessageID(), reason: .noOverlap)), to: P15.bob, conversation: fresh)
        #expect(await wire.sent.count == 1)
        // The fake stands for a retained store; actual disk reopening and
        // failure recovery are separate lane A integrations in #49.
    }

    @Test func ledgerReadWriteAndRetirementErrorsNeverBecomeEmptyState() async throws {
        for failure in FaultLedger.Failure.allCases {
            let ledger = FaultLedger(failure)
            let wire = RecordingTransport(localPeer: P15.alice)
            let observer = RecordingOutboxObserver()
            let sequences = InMemorySentSequenceStore()
            let outbox = Self.box(wire, ledger, observer: observer, sequences: sequences)
            let conversation = ConversationID()
            await #expect(throws: FaultLedger.Unavailable.self) {
                if failure == .retire {
                    try await outbox.retire(conversation)
                } else {
                    try await outbox.send(Self.answer(.count(1)), to: P15.bob, conversation: conversation,
                        context: OutboundContext(answering: Query(issue: .interests, candidates: .count(1))))
                }
            }
            #expect(await wire.sent.isEmpty)
            #expect(await observer.announced.isEmpty)
            #expect(sequences.highestSent(in: conversation, to: P15.bob) == nil)
        }
    }
}

private actor FaultLedger: ConversationLedger {
    enum Failure: CaseIterable { case read, reserve, retire }
    struct Unavailable: Error {}
    let failure: Failure
    let storage = InMemoryConversationLedger()
    init(_ failure: Failure) { self.failure = failure }
    func isRetired(_ conversation: ConversationID) async throws -> Bool {
        if failure == .read { throw Unavailable() }
        return try await storage.isRetired(conversation)
    }
    func retire(_ conversation: ConversationID) async throws {
        if failure == .retire { throw Unavailable() }
        try await storage.retire(conversation)
    }
    func reserve(_ candidates: [IssueValue], issue: IssueKey, to peer: PeerID, in conversation: ConversationID) async throws -> Bool {
        if failure == .reserve { throw Unavailable() }
        return try await storage.reserve(candidates, issue: issue, to: peer, in: conversation)
    }
}
