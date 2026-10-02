import Foundation
import SimulatorKit
import StarlingCore
import StarlingFakes
import StarlingFeatures
import StarlingPolicy
import Testing

@Suite(.timeLimit(.minutes(1))) struct SequenceAndAuditAttackTests {
    @MainActor @Test func refusedSendsLeaveNeitherSequenceGapsNorPolicyRejectionsOnWire() async throws {
        let consent = ConsentCoordinator(peers: nil, timeout: .seconds(5), now: { P15.date })
        let wire = RecordingTransport(localPeer: P15.alice)
        let observer = RecordingOutboxObserver()
        let store = InMemorySentSequenceStore()
        let rules = OwnerRules(constraints: .empty, disclosure: try PrivacySettings([.budget: .never]).disclosureRules)
        let outbox = Outbox(transport: wire, policy: DeterministicPolicyEngine(ownerRules: rules),
                            consent: consent, observer: observer, sequences: store, now: { P15.date })
        let conversation = ConversationID()
        let card = try P15.card([SampleSkills.pickAPlace.ref])
        let ordinaryNo = MessageBody.reject(Rejection(proposal: MessageID(), reason: .noOverlap))
        func send(_ body: MessageBody) async throws -> Envelope {
            try await outbox.send(body, to: P15.bob, conversation: conversation, recipientCard: card,
                                  skill: SampleSkills.pickAPlace.ref, mode: .invite)
        }
        let first = try await send(ordinaryNo)
        let secret = try P15.bodies(issue: .budget, value: .amount(MoneyAmount(minorUnits: 1234)))[0]
        await #expect(throws: OutboxError.denied(PolicyViolation(rule: PolicyRuleID.never, issue: .budget))) {
            try await send(secret)
        }
        #expect(store.highestSent(in: conversation, to: P15.bob) == first.sequence)
        let asks = try P15.bodies(issue: .place, value: P15.value(.place))[0]
        for cancel in [false, true] {
            let task = Task { try await send(asks) }
            defer { task.cancel() }
            try await Simulation.eventually("pending consent") { await consent.current != nil }
            let sheet = try #require(consent.current)
            if cancel { task.cancel() } else { consent.answer(.declined, to: sheet.id) }
            await #expect(throws: OutboxError.consentDeclined) { try await task.value }
            #expect(consent.current == nil)
            #expect(store.highestSent(in: conversation, to: P15.bob) == first.sequence)
        }
        let after = try await send(ordinaryNo)
        #expect(after.sequence == first.sequence + 1)
        #expect(await wire.sent.count == 2)
        #expect(await observer.records.count == 2)
        for sent in await wire.sent {
            let decoded = try EnvelopeCodec().decode(sent.frame.bytes)
            #expect(decoded.body == ordinaryNo)
            guard case .reject(let rejection) = decoded.body else { Issue.record("Unexpected egress"); continue }
            #expect(rejection.reason == .noOverlap)
        }
        // This verifies Outbox silence and a valid ordinary-no send. Actual
        // service mapping from a Never denial to noOverlap remains in #49.
    }

    @Test func persistedSequenceSurvivesClockRollbackAndInboxKeepsOldFramesRejected() async throws {
        let wire = RecordingTransport(localPeer: P15.alice)
        let store = InMemorySentSequenceStore()
        let conversation = ConversationID()
        let body = MessageBody.reject(Rejection(proposal: MessageID(), reason: .noOverlap))
        let before = Outbox(transport: wire, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                            sequences: store, now: { P15.date })
        let first = try await before.send(body, to: P15.bob, conversation: conversation, skill: SampleSkills.downFor.ref, mode: .askQuietly)
        let relaunched = Outbox(transport: wire, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                                sequences: store, now: { P15.date.addingTimeInterval(-60) })
        let second = try await relaunched.send(body, to: P15.bob, conversation: conversation, skill: SampleSkills.downFor.ref, mode: .askQuietly)
        #expect(second.sequence == first.sequence + 1)
        let inbox = Inbox(localPeer: P15.bob, now: { P15.date })
        let firstFrame = try Frame(EnvelopeCodec().encode(first))
        #expect(try await inbox.accept(firstFrame, from: P15.alice).get() == first)
        #expect(try await inbox.accept(Frame(EnvelopeCodec().encode(second)), from: P15.alice).get() == second)
        #expect(await inbox.accept(firstFrame, from: P15.alice) == .failure(.replay))
    }

    @Test func sequenceExhaustionAndStorageFailureCannotSendOrAudit() async throws {
        for brokenDisk in [false, true] {
            let conversation = ConversationID()
            let store = InMemorySentSequenceStore(brokenDisk ? [:] : [conversation: [P15.bob: UInt64.max - 1]])
            if brokenDisk { store.failWrites() }
            let wire = RecordingTransport(localPeer: P15.alice)
            let observer = RecordingOutboxObserver()
            let outbox = Outbox(transport: wire, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                                observer: observer, sequences: store, now: { P15.date })
            let body = MessageBody.reject(Rejection(proposal: MessageID(), reason: .noOverlap))
            if brokenDisk {
                await #expect(throws: InMemorySentSequenceStore.WriteFailed.self) {
                    try await outbox.send(body, to: P15.bob, conversation: conversation)
                }
            } else {
                await #expect(throws: OutboxError.sequenceExhausted) {
                    try await outbox.send(body, to: P15.bob, conversation: conversation)
                }
            }
            #expect(await wire.sent.isEmpty)
            #expect(await observer.records.isEmpty)
        }
    }

    @Test func auditNeverTreatsUnknownItemsAsProofOfPrivacyAndMessageWritesAreIdempotent() async throws {
        var interaction = P15.interaction()
        let observer = RecordingOutboxObserver()
        let wire = RecordingTransport(localPeer: P15.alice)
        let outbox = Outbox(transport: wire, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                            observer: observer, now: { P15.date })
        let envelope = try await outbox.send(.reject(Rejection(proposal: MessageID(), reason: .noOverlap)),
            to: P15.bob, conversation: interaction.conversation, context: OutboundContext(interaction: interaction.id),
            skill: interaction.skill, mode: .askQuietly)
        let sent = try #require(await observer.records.first)
        #expect(sent.disclosed == nil)
        let unknown = EgressRecord(at: envelope.sentAt, recipient: envelope.recipient, items: [],
                                   message: envelope.id, itemsUnknown: sent.disclosed == nil)
        interaction.record(unknown)
        interaction = try P15.restart(interaction)
        interaction.record(unknown)
        #expect(interaction.egress.count == 1 && !interaction.egressIsKnown)
        // A conflicting duplicate cannot silently replace an unknown record.
        interaction.record(EgressRecord(at: envelope.sentAt, recipient: envelope.recipient, items: [], message: envelope.id))
        #expect(interaction.egress == [unknown] && !interaction.egressIsKnown)
    }
}
