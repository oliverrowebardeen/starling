import Foundation
import SimulatorKit
import StarlingCore
import StarlingFakes
import StarlingPolicy
import Testing

@Suite(.timeLimit(.minutes(1))) struct JournalAndRetirementAttackTests {
    static var ordinaryNo: MessageBody { .reject(Rejection(proposal: MessageID(), reason: .noOverlap)) }

    @Test func authenticatedFriendsSeeOnlyTheirOwnSequenceProgressAfterReplacement() async throws {
        let simulation = Simulation(now: { P15.date }, security: .secureChannel)
        do {
            let alice = try await simulation.addAgent("alice")
            let bob = try await simulation.addAgent("bob")
            let eve = try await simulation.addAgent("eve")
            try await simulation.waitForMesh()
            let channel = try #require(alice.secureTransport)
            let ledger = InMemoryConversationLedger()
            let sequences = InMemorySentSequenceStore()
            let conversation = ConversationID()
            func box(_ offset: TimeInterval) -> Outbox {
                Outbox(transport: channel, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                       sequences: sequences, ledger: ledger, now: { P15.date.addingTimeInterval(offset) })
            }
            let first = box(0)
            let toBob = try await first.send(Self.ordinaryNo, to: bob.id, conversation: conversation)
            var toEve: [Envelope] = []
            for _ in 0..<9 { toEve.append(try await first.send(Self.ordinaryNo, to: eve.id, conversation: conversation)) }
            let restarted = box(-60)
            let toBobAgain = try await restarted.send(Self.ordinaryNo, to: bob.id, conversation: conversation)
            let toEveAgain = try await restarted.send(Self.ordinaryNo, to: eve.id, conversation: conversation)
            #expect(toEve.first?.sequence == toBob.sequence)
            #expect(toBobAgain.sequence == toBob.sequence + 1)
            #expect(toEveAgain.sequence == toEve[8].sequence + 1)
            try await Simulation.eventually("both friends received their final numbered message") {
                let b = await bob.received.contains(toBobAgain)
                let e = await eve.received.contains(toEveAgain)
                return b && e
            }
            #expect(await bob.received.filter { $0.conversation == conversation } == [toBob, toBobAgain])
            #expect(sequences.highestSent(in: conversation, to: bob.id) == toBobAgain.sequence)
            #expect(sequences.highestSent(in: conversation, to: eve.id) == toEveAgain.sequence)
            await simulation.stop()
        } catch {
            await simulation.stop()
            throw error
        }
    }

    @Test(arguments: [false, true])
    func retirementCancelsAnOfferInsideTheSecureQueueEvenIfTheWriteFails(retirementWriteFails: Bool) async throws {
        // The injected link delay keeps a sealed send in flight while the next
        // conversation waits inside the real SecureTransport queue.
        let simulation = Simulation(latency: .seconds(1), now: { P15.date }, security: .secureChannel)
        do {
            let alice = try await simulation.addAgent("alice")
            let bob = try await simulation.addAgent("bob")
            try await simulation.waitForMesh(timeout: .seconds(15))
            let channel = try #require(alice.secureTransport)
            let transport = SendEntryProbe(channel)
            let ledger = InMemoryConversationLedger()
            let journal = LedgerJournal()
            let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                                observer: journal, ledger: ledger, now: { P15.date })
            let other = ConversationID()
            let withdrawn = ConversationID()
            let first = Task { try await outbox.send(Self.ordinaryNo, to: bob.id, conversation: other) }
            defer { first.cancel() }
            try await Simulation.eventually("unrelated send entered the secure transport") { await transport.entered.count == 1 }
            let queued = Task {
                try await outbox.send(.propose(Proposal(round: 0, terms: P15.proposal(1).terms)),
                    to: bob.id, conversation: withdrawn, skill: SampleSkills.downFor.ref, mode: .invite)
            }
            defer { queued.cancel() }
            try await Simulation.eventually("withdrawn offer entered the secure queue") { await transport.entered.count == 2 }
            // Require the injected suspension to be live, rather than treating
            // a send already delivered as evidence about queue cancellation.
            try #require(await transport.completed.isEmpty)
            if retirementWriteFails {
                await ledger.failAll()
                await #expect(throws: InMemoryConversationLedger.Unavailable.self) { try await outbox.retire(withdrawn) }
            } else {
                try await outbox.retire(withdrawn)
            }
            let delivered = try await first.value
            await #expect(throws: CancellationError.self) { try await queued.value }
            try await Simulation.eventually("the unrelated conversation still arrives") { await bob.received.contains(delivered) }
            #expect(await bob.received.filter { $0.conversation == withdrawn }.isEmpty)
            #expect(await transport.completed.map(\.conversation) == [other])
            #expect(await journal.settled.map(\.conversation) == [other])
            #expect(await journal.pending.values.map(\.draft.conversation) == [withdrawn])
            if retirementWriteFails {
                await #expect(throws: InMemoryConversationLedger.Unavailable.self) {
                    try await outbox.send(Self.ordinaryNo, to: bob.id, conversation: withdrawn)
                }
            } else {
                #expect(try await ledger.isRetired(withdrawn))
                await #expect(throws: OutboxError.conversationRetired) {
                    try await outbox.send(Self.ordinaryNo, to: bob.id, conversation: withdrawn)
                }
            }
            await simulation.stop()
        } catch {
            await simulation.stop()
            throw error
        }
    }

    @Test func aRefusedJournalKeepsTheCandidateReservationButTakesNoSequence() async throws {
        let wire = RecordingTransport(localPeer: P15.alice)
        let ledger = InMemoryConversationLedger()
        let sequences = InMemorySentSequenceStore()
        let journal = LedgerJournal(refusing: true)
        let outbox = ConversationLedgerAttackTests.box(wire, ledger, observer: journal, sequences: sequences)
        let conversation = ConversationID()
        let slots = IssueValue.slots(try (0..<16).map { try TimeSlot(startMinute: Int64($0 * 60), endMinute: Int64($0 * 60 + 30)) })
        let query = try Query(issue: .interests, candidates: slots)
        await #expect(throws: LedgerJournal.WriteFailed.self) {
            try await outbox.send(ConversationLedgerAttackTests.answer(.slots([])), to: P15.bob, conversation: conversation,
                                  context: OutboundContext(answering: query))
        }
        #expect(await wire.sent.isEmpty)
        #expect(await journal.settled.isEmpty)
        #expect(sequences.highestSent(in: conversation, to: P15.bob) == nil)
        #expect(await ledger.answeredCount(issue: .interests, to: P15.bob, in: conversation) == 16)
        // Losing a journal write or replacing the Outbox cannot replenish the
        // budget that the durable reservation already consumed.
        let recovered = ConversationLedgerAttackTests.box(wire, ledger, sequences: sequences)
        let extra = try Query(issue: .interests, candidates: .count(17))
        await #expect(throws: OutboxError.answerLimitReached) {
            try await recovered.send(ConversationLedgerAttackTests.answer(.count(17)), to: P15.bob, conversation: conversation,
                                     context: OutboundContext(answering: extra))
        }
        try await recovered.send(ConversationLedgerAttackTests.answer(.slots([])), to: P15.bob, conversation: conversation,
                                 context: OutboundContext(answering: query))
        #expect(await wire.sent.count == 1)
    }

    @Test(arguments: [false, true])
    func retirementOrLedgerFailureDuringJournalSuspensionStopsTransport(failingLedger: Bool) async throws {
        let wire = RecordingTransport(localPeer: P15.alice)
        let ledger = InMemoryConversationLedger()
        let sequences = InMemorySentSequenceStore()
        let journal = LedgerJournal(blocking: true)
        let outbox = ConversationLedgerAttackTests.box(wire, ledger, observer: journal, sequences: sequences)
        let conversation = ConversationID()
        let pending = Task { try await outbox.send(Self.ordinaryNo, to: P15.bob, conversation: conversation) }
        defer { pending.cancel(); Task { await journal.release() } }
        try await Simulation.eventually("journal note before transport") { await journal.pending.count == 1 }
        #expect(await wire.sent.isEmpty)
        if failingLedger { await ledger.failAll() } else { try await outbox.retire(conversation) }
        await journal.release()
        if failingLedger {
            await #expect(throws: InMemoryConversationLedger.Unavailable.self) { try await pending.value }
        } else {
            // Retirement now cancels the entire suspended send (PR #85).
            // A fresh send still encounters the durable retired record.
            await #expect(throws: CancellationError.self) { try await pending.value }
            await #expect(throws: OutboxError.conversationRetired) {
                try await outbox.send(Self.ordinaryNo, to: P15.bob, conversation: conversation)
            }
        }
        #expect(await wire.sent.isEmpty)
        #expect(await journal.pending.count == 1)
        #expect(await journal.settled.isEmpty)
        #expect(sequences.highestSent(in: conversation, to: P15.bob) == nil)
    }

    @Test func journalPrecedesTransportAndAnAmbiguousFailureNeverSettlesIt() async throws {
        for failAfterCapture in [false, true] {
            let wire = LedgerWire(failAfterCapture: failAfterCapture)
            let ledger = InMemoryConversationLedger()
            let journal = LedgerJournal(blocking: true)
            let outbox = Outbox(transport: wire, policy: DeterministicPolicyEngine(), consent: ScriptedConsentProvider(.approved),
                                observer: journal, ledger: ledger, now: { P15.date })
            let value = try P15.value(.place)
            let terms = try Terms([.place: value])
            let localID = InteractionID()
            let pending = Task {
                try await outbox.send(.propose(Proposal(round: 0, terms: terms)), to: P15.bob, conversation: ConversationID(),
                    context: OutboundContext(interaction: localID), skill: SampleSkills.pickAPlace.ref, mode: .invite)
            }
            defer { pending.cancel(); Task { await journal.release() } }
            try await Simulation.eventually("durable note before attempted transport") { await journal.pending.count == 1 }
            let note = try #require(await journal.pending.values.first)
            #expect(await wire.captured.isEmpty)
            #expect(note.draft.sequence == 0)
            #expect(note.context.interaction == localID)
            #expect(note.disclosed == [DisclosedItem(category: .terms, issue: .place, value: value)])
            await journal.release()
            if failAfterCapture {
                await #expect(throws: LedgerWire.LinkLost.self) { try await pending.value }
                #expect(await journal.pending.count == 1)
                #expect(await journal.settled.isEmpty)
            } else {
                let sent = try await pending.value
                #expect(sent.id == note.draft.id && sent.sequence > 0)
                #expect(await journal.pending.isEmpty)
                #expect(await journal.settled == [sent])
            }
            #expect(await wire.captured.map(\.id) == [note.draft.id])
            // A pending note is evidence for E's restart-to-unknown integration,
            // not a claim that this probe implements the production journal.
        }
    }

    @Test func cancellingBeforeNumberingLeavesNoGapAndRollbackRestartHasOnlyTheAcceptedGap() async throws {
        let wire = LedgerWire(blocking: true)
        let ledger = InMemoryConversationLedger()
        let journal = LedgerJournal()
        let sequences = InMemorySentSequenceStore()
        let conversation = ConversationID()
        let outbox = Outbox(transport: wire, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                            observer: journal, sequences: sequences, ledger: ledger, now: { P15.date })
        let first = Task { try await outbox.send(Self.ordinaryNo, to: P15.bob, conversation: conversation) }
        defer { first.cancel(); Task { await wire.release() } }
        try await Simulation.eventually("first send waits in transport") { await wire.waiting }
        let queued = Task { try await outbox.send(Self.ordinaryNo, to: P15.bob, conversation: conversation) }
        defer { queued.cancel() }
        try await Simulation.eventually("second send cleared its journal") { await journal.pending.count == 2 }
        let numbered = sequences.highestSent(in: conversation, to: P15.bob)
        queued.cancel()
        await wire.release()
        let initial = try await first.value
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(sequences.highestSent(in: conversation, to: P15.bob) == numbered)
        let afterQueued = try await outbox.send(Self.ordinaryNo, to: P15.bob, conversation: conversation)
        #expect(afterQueued.sequence == initial.sequence + 1)
        await wire.cancelNext()
        await #expect(throws: CancellationError.self) {
            try await outbox.send(Self.ordinaryNo, to: P15.bob, conversation: conversation)
        }
        let reused = try await outbox.send(Self.ordinaryNo, to: P15.bob, conversation: conversation)
        #expect(reused.sequence == afterQueued.sequence + 1)
        await wire.cancelNext()
        await #expect(throws: CancellationError.self) {
            try await outbox.send(Self.ordinaryNo, to: P15.bob, conversation: conversation)
        }
        let restarted = Outbox(transport: wire, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                              sequences: sequences, ledger: ledger, now: { P15.date.addingTimeInterval(-60) })
        let afterRestart = try await restarted.send(Self.ordinaryNo, to: P15.bob, conversation: conversation)
        #expect(afterRestart.sequence == reused.sequence + 2) // ADR 0021 amendment 11.
        #expect(await wire.captured.map(\.sequence) == [initial.sequence, afterQueued.sequence, reused.sequence, afterRestart.sequence])
    }

    enum PolicyChange: CaseIterable, Sendable {
        case shareToNever, askToNever, shareToAsk, unchangedApproval, askToShare
        var initial: SharingChoice {
            switch self { case .shareToNever, .shareToAsk: .share; default: .askMe }
        }
        var final: SharingChoice {
            switch self {
            case .shareToNever, .askToNever: .never
            case .shareToAsk, .unchangedApproval: .askMe
            case .askToShare: .share
            }
        }
        var failure: OutboxError? {
            switch self {
            case .shareToNever, .askToNever: .denied(PolicyViolation(rule: PolicyRuleID.never, issue: .place))
            case .shareToAsk: .policyChangedDuringConsent
            case .unchangedApproval, .askToShare: nil
            }
        }
    }

    @Test(arguments: PolicyChange.allCases, [false, true])
    func lastPolicyCheckHonorsPrivacyChangesAfterJournalOrSameFriendQueue(change: PolicyChange, queued: Bool) async throws {
        let friend = try PairedPeer(publicKey: IdentityPublicKey(hex: String(repeating: "bb", count: 32)), nickname: "Sam", pairedAt: P15.now)
        let peers = InMemoryPairedPeerStore([friend])
        func engine(_ choice: SharingChoice) throws -> DeterministicPolicyEngine {
            DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty,
                disclosure: try PrivacySettings([.place: choice]).disclosureRules), pairedPeers: peers)
        }
        let policy = ReplaceablePolicy(try engine(change.initial))
        let wire = LedgerWire(blocking: queued)
        let journal = LedgerJournal(blocking: !queued)
        let ledger = InMemoryConversationLedger()
        let sequences = InMemorySentSequenceStore()
        let consent = ScriptedConsentProvider(.approved)
        let outbox = Outbox(transport: wire, policy: policy, consent: consent, observer: journal,
                            sequences: sequences, ledger: ledger, now: { P15.date })
        let conversation = ConversationID()
        let blocking: Task<Envelope, any Error>? = queued ? Task {
            try await outbox.send(Self.ordinaryNo, to: friend.id, conversation: conversation,
                                  recipientCard: P15.card([SampleSkills.pickAPlace.ref]))
        } : nil
        defer { blocking?.cancel(); Task { await wire.release(); await journal.release() } }
        if queued { try await Simulation.eventually("earlier send blocks this friend's queue") { await wire.waiting } }
        let value = try P15.value(.place)
        let terms = try Terms([.place: value])
        let privateSend = Task {
            try await outbox.send(.propose(Proposal(round: 0, terms: terms)), to: friend.id, conversation: conversation,
                recipientCard: P15.card([SampleSkills.pickAPlace.ref]), skill: SampleSkills.pickAPlace.ref, mode: .invite)
        }
        defer { privateSend.cancel() }
        try await Simulation.eventually("private send cleared the original policy and consent") {
            await journal.pending.count == (queued ? 2 : 1)
        }
        let numbered = sequences.highestSent(in: conversation, to: friend.id)
        await policy.install(try engine(change.final))
        await journal.release()
        await wire.release()
        if let blocking { _ = try await blocking.value }
        if let failure = change.failure {
            await #expect(throws: failure) { try await privateSend.value }
            #expect(sequences.highestSent(in: conversation, to: friend.id) == numbered)
            #expect(await journal.pending.count == 1)
        } else {
            let sent = try await privateSend.value
            #expect(await wire.captured.contains(sent))
            #expect(await journal.pending.isEmpty)
        }
        let successful = (queued ? 1 : 0) + (change.failure == nil ? 1 : 0)
        #expect(await wire.captured.count == successful)
        #expect(await journal.settled.count == successful)
        // A newly required consent does not silently reuse an earlier allow.
        // An unchanged explicit approval remains a valid positive control.
        #expect(await consent.requests.count == (change.initial == .askMe ? 1 : 0))
    }

    @Test func cancelInFlightStopsAllWaitingConversationsAndRecipientsWithoutRetiringThem() async throws {
        let wire = LedgerWire(blocking: true)
        let ledger = InMemoryConversationLedger()
        let journal = LedgerJournal()
        let sequences = InMemorySentSequenceStore()
        let outbox = Outbox(transport: wire, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                            observer: journal, sequences: sequences, ledger: ledger, now: { P15.date })
        let one = ConversationID(), two = ConversationID()
        let scopes = [(one, P15.bob), (one, P15.eve), (two, P15.bob), (two, P15.eve)]
        let sends = scopes.map { conversation, peer in
            Task { try await outbox.send(Self.ordinaryNo, to: peer, conversation: conversation) }
        }
        defer { for send in sends { send.cancel() }; Task { await wire.release() } }
        try await Simulation.eventually("every scope waits inside transport") { await wire.entered.count == scopes.count }
        let numbered = scopes.map { sequences.highestSent(in: $0.0, to: $0.1) }
        await outbox.cancelInFlight()
        await wire.release()
        for send in sends { await #expect(throws: CancellationError.self) { try await send.value } }
        #expect(await wire.captured.isEmpty)
        #expect(await journal.pending.count == scopes.count)
        #expect(await journal.settled.isEmpty)
        for (index, scope) in scopes.enumerated() {
            #expect(try await !ledger.isRetired(scope.0))
            let fresh = try await outbox.send(Self.ordinaryNo, to: scope.1, conversation: scope.0)
            #expect(fresh.sequence == numbered[index])
        }
        #expect(await wire.captured.count == scopes.count)
    }
}

private actor ReplaceablePolicy: PolicyEngine {
    private var engine: any PolicyEngine
    init(_ engine: any PolicyEngine) { self.engine = engine }
    func install(_ engine: any PolicyEngine) { self.engine = engine }
    func evaluate(_ message: OutboundMessage) async -> PolicyDecision { await engine.evaluate(message) }
    func disclosedItems(for message: OutboundMessage) async throws -> [DisclosedItem] { try await engine.disclosedItems(for: message) }
}

private actor LedgerJournal: OutboxObserver {
    struct WriteFailed: Error {}
    struct Note: Sendable {
        let draft: Envelope
        let context: OutboundContext
        let disclosed: [DisclosedItem]?
    }
    private(set) var pending: [MessageID: Note] = [:]
    private(set) var settled: [Envelope] = []
    private let refusing: Bool
    private var blocking: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(refusing: Bool = false, blocking: Bool = false) { self.refusing = refusing; self.blocking = blocking }
    func release() { blocking = false; for waiter in waiters { waiter.resume() }; waiters = [] }
    func outbox(willSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async throws {
        if refusing { throw WriteFailed() }
        pending[envelope.id] = Note(draft: envelope, context: context, disclosed: disclosed)
        if blocking { await withCheckedContinuation { waiters.append($0) } }
    }
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {
        pending[envelope.id] = nil
        settled.append(envelope)
    }
}

/// Send-only probe on the simulation's channel. Its original Inbox remains
/// the only reader. Protocol forwarding here still runs under an Outbox.
private actor SendEntryProbe: Transport {
    nonisolated let localPeer: PeerID
    nonisolated let kind: TransportKind
    nonisolated let events = AsyncStream<TransportEvent> { $0.finish() }
    let wrapped: any Transport
    private(set) var entered: [Envelope] = []
    private(set) var completed: [Envelope] = []
    init(_ wrapped: any Transport) { self.wrapped = wrapped; localPeer = wrapped.localPeer; kind = wrapped.kind }
    func start() async throws {}
    func stop() async {}
    func send(_ frame: Frame, to peer: PeerID) async throws {
        let envelope = try EnvelopeCodec().decode(frame.bytes)
        entered.append(envelope)
        try await wrapped.send(frame, to: peer)
        completed.append(envelope)
    }
}

private actor LedgerWire: Transport {
    struct LinkLost: Error {}
    nonisolated let localPeer = P15.alice
    nonisolated let kind = TransportKind.loopback
    nonisolated let events = AsyncStream<TransportEvent> { $0.finish() }
    private let failAfterCapture: Bool
    private var blocking: Bool
    private var dropNext = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waiting = false
    private(set) var entered: [Envelope] = []
    private(set) var captured: [Envelope] = []
    init(failAfterCapture: Bool = false, blocking: Bool = false) { self.failAfterCapture = failAfterCapture; self.blocking = blocking }
    func start() async throws {}
    func stop() async { release() }
    func release() { blocking = false; waiting = false; for waiter in waiters { waiter.resume() }; waiters = [] }
    func cancelNext() { dropNext = true }
    func send(_ frame: Frame, to peer: PeerID) async throws {
        entered.append(try EnvelopeCodec().decode(frame.bytes))
        if blocking { waiting = true; await withCheckedContinuation { waiters.append($0) } }
        try Task.checkCancellation()
        if dropNext { dropNext = false; throw CancellationError() }
        captured.append(try EnvelopeCodec().decode(frame.bytes))
        if failAfterCapture { throw LinkLost() }
    }
}
