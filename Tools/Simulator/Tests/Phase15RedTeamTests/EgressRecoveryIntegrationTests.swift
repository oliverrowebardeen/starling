import Foundation
import PickAPlace
import StarlingChaining
import StarlingCore
import StarlingFakes
import StarlingFeatures
import StarlingPolicy
import Testing

@Suite("P15-F real egress recorder recovery", .serialized)
struct EgressRecoveryIntegrationTests {
    @Test func interruptedSendBecomesUnknownAfterRecorderReplacement() async throws {
        let interaction = P15.interaction(PickAPlaceSkill.descriptor)
        let store = InMemoryInteractionStore([interaction])
        let journal = InMemoryEgressJournal()
        let sink = StoreEgressSink(store: store)
        let recorder = EgressRecorder(sink: sink, journal: journal, now: { P15.date })
        let transport = RecordingTransport(localPeer: P15.alice)
        await transport.failSends(with: .failed("injected ambiguous failure"))
        let outbox = Outbox(transport: transport, policy: DeterministicPolicyEngine(ownerRules: .empty),
            consent: ScriptedConsentProvider(.approved), observer: recorder, ledger: InMemoryConversationLedger(), now: { P15.date })
        await #expect(throws: (any Error).self) {
            try await outbox.send(.propose(Proposal(round: 0, terms: Terms([.place: P15.value(.place)]))),
                to: P15.bob, conversation: interaction.conversation, skill: interaction.skill, mode: .invite)
        }
        let pending = try #require(await journal.unresolved().first)
        #expect(!pending.sent)
        #expect(await recorder.unconfirmedConversations == [interaction.conversation])
        #expect(try await store.interaction(interaction.id)?.egress.isEmpty == true)
        let recovered = EgressRecorder(sink: sink, journal: journal, now: { P15.date })
        await recovered.recover()
        let saved = try #require(await store.interaction(interaction.id))
        #expect(saved.egress.count == 1 && !saved.egressIsKnown)
        #expect(saved.egress.first?.message == pending.message)
        let audit = WhatLeftYourPhone(interactions: [saved], registry: ChainFixture.registry)
        #expect(audit.kept.isEmpty && audit.unconfirmed == [interaction.id])
        #expect(try await journal.unresolved().isEmpty)
        await recovered.recover()
        #expect(try await store.interaction(interaction.id)?.egress.count == 1)
    }

    @Test func journalFailureStopsEgressAndSinkFailureRemainsRetryable() async throws {
        let interaction = P15.interaction(PickAPlaceSkill.descriptor)
        let store = InMemoryInteractionStore([interaction])
        let journal = InMemoryEgressJournal()
        await journal.failAll()
        let broken = EgressRecorder(sink: StoreEgressSink(store: store), journal: journal)
        let transport = RecordingTransport(localPeer: P15.alice)
        let outbox = Outbox(transport: transport, policy: DeterministicPolicyEngine(ownerRules: .empty),
            consent: ScriptedConsentProvider(.approved), observer: broken, ledger: InMemoryConversationLedger(), now: { P15.date })
        let body = MessageBody.propose(try Proposal(round: 0, terms: Terms([.place: P15.value(.place)])))
        await #expect(throws: InMemoryEgressJournal.Unavailable.self) {
            try await outbox.send(body, to: P15.bob, conversation: interaction.conversation, skill: interaction.skill, mode: .invite)
        }
        #expect(await transport.sent.isEmpty)
        await broken.recover()
        #expect(await broken.journalUnreadable)

        let goodJournal = InMemoryEgressJournal()
        let sink = RetryingEgressSink(store: store)
        let recorder = EgressRecorder(sink: sink, journal: goodJournal)
        let retrying = Outbox(transport: transport, policy: DeterministicPolicyEngine(ownerRules: .empty),
            consent: ScriptedConsentProvider(.approved), observer: recorder, ledger: InMemoryConversationLedger(), now: { P15.date })
        let envelope = try await retrying.send(body, to: P15.bob, conversation: interaction.conversation, skill: interaction.skill, mode: .invite)
        #expect(await recorder.unconfirmedConversations == [interaction.conversation])
        #expect(try await goodJournal.unresolved().first?.sent == true)
        let unknown = WhatLeftYourPhone(interactions: [try #require(await store.interaction(interaction.id))],
            registry: ChainFixture.registry, unconfirmed: await recorder.unconfirmedConversations)
        #expect(unknown.kept.isEmpty)
        await sink.allow()
        let replacement = EgressRecorder(sink: sink, journal: goodJournal)
        await replacement.recover()
        await replacement.retryPending()
        let saved = try #require(await store.interaction(interaction.id))
        #expect(saved.egress.count == 1 && saved.egress.first?.message == envelope.id && saved.egressIsKnown)
        let audit = WhatLeftYourPhone(interactions: [saved], registry: ChainFixture.registry)
        #expect(audit.shared.map(\.topic) == [.place])
        #expect(audit.kept.contains(.topic(.location)))
        #expect(audit.kept.contains(.topic(.budget)))
    }

    @Test func exactOfferedTermsReachTheActualAuditOnceAndUnknownVersionsClaimNothingKept() async throws {
        let interaction = P15.interaction(PickAPlaceSkill.descriptor)
        let store = InMemoryInteractionStore([interaction])
        let peer = try PairedPeer(publicKey: IdentityPublicKey(hex: String(repeating: "bb", count: 32)), nickname: "Sam", pairedAt: P15.now)
        let policy = DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty,
            disclosure: try PrivacySettings([.place: .never, .people: .never]).disclosureRules), pairedPeers: InMemoryPairedPeerStore([peer]))
        let journal = InMemoryEgressJournal()
        let recorder = EgressRecorder(sink: StoreEgressSink(store: store), journal: journal)
        let transport = RecordingTransport()
        let consent = ScriptedConsentProvider(.approved)
        let outbox = Outbox(transport: transport, policy: policy, consent: consent, observer: recorder, ledger: InMemoryConversationLedger())
        let offer = try Proposal(round: 0, terms: Terms([.place: P15.value(.place), .people: .peers([transport.localPeer, peer.id])]))
        let sent = try await outbox.send(.accept(Acceptance(proposal: MessageID(), terms: offer.terms)), to: peer.id,
            conversation: interaction.conversation, recipientCard: P15.card([interaction.skill]),
            context: OutboundContext(interaction: interaction.id, accepting: offer), skill: interaction.skill, mode: .invite)
        #expect(await consent.requests.isEmpty)
        let saved = try #require(await store.interaction(interaction.id))
        #expect(saved.egress.count == 1 && saved.egress.first?.message == sent.id)
        #expect(Set(saved.egress.flatMap(\.items).compactMap(\.issue)) == [.place, .people])
        var unknown = Interaction(skill: SkillRef(.pickAPlace, SkillVersion(99)), role: .invitee, participants: [peer.id], createdAt: P15.now)
        unknown.record(EgressRecord(at: P15.now, recipient: peer.id, items: [], message: MessageID(), itemsUnknown: true))
        let audit = WhatLeftYourPhone(interactions: [saved, unknown], registry: ChainFixture.registry)
        #expect(audit.kept.isEmpty && audit.unconfirmed == [unknown.id])
    }

    @Test func diskLedgerAndRecipientNumbersSurviveReopeningAndLatchWriteFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "p15f-durable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = JSONFile(url: directory.appending(path: "ledger.json"))
        let ledger = FileConversationLedger(file: file)
        let conversation = ConversationID(), retired = ConversationID()
        let candidates: [IssueValue] = (0..<16).map { .count($0) }
        #expect(try await ledger.reserve(candidates, issue: .photos, to: P15.bob, in: conversation))
        try await ledger.retire(retired)
        for _ in 0..<300 { try await ledger.retire(ConversationID()) }
        let reopened = FileConversationLedger(file: file)
        #expect(try await reopened.isRetired(retired))
        #expect(try await !reopened.reserve([.count(16)], issue: .photos, to: P15.bob, in: conversation))
        #expect(try await reopened.reserve([.count(16)], issue: .photos, to: P15.eve, in: conversation))
        let sequenceFile = JSONFile(url: directory.appending(path: "sequences.json"))
        let sequences = FileSentSequenceStore(file: sequenceFile)
        try sequences.recordSent(100, in: conversation, to: P15.bob)
        try sequences.recordSent(7, in: conversation, to: P15.eve)
        let restored = FileSentSequenceStore(file: sequenceFile)
        #expect(restored.highestSent(in: conversation, to: P15.bob) == 100)
        #expect(restored.highestSent(in: conversation, to: P15.eve) == 7)
        // Start from a loaded, valid cache, then make the real write fail.
        try FileManager.default.removeItem(at: file.url)
        try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await reopened.retire(conversation) }
        await #expect(throws: FileConversationLedger.Unreadable.self) { try await reopened.isRetired(conversation) }
        let outbox = Outbox(transport: RecordingTransport(), policy: FixedPolicyEngine(.allow),
            consent: ScriptedConsentProvider(.approved), ledger: reopened)
        await #expect(throws: FileConversationLedger.Unreadable.self) {
            try await outbox.send(.reject(Rejection(proposal: MessageID(), reason: .noOverlap)), to: P15.bob, conversation: ConversationID())
        }
    }
}

private actor RetryingEgressSink: EgressSink {
    private let sink: StoreEgressSink
    private var failing = true
    init(store: any InteractionStore) { sink = StoreEgressSink(store: store) }
    func allow() { failing = false }
    func appendEgress(_ record: EgressRecord, conversation: ConversationID) async throws -> Bool {
        if failing { throw LedgerUnavailable() }
        return try await sink.appendEgress(record, conversation: conversation)
    }
}
