import Foundation
import StarlingChaining
import StarlingCore
import StarlingFakes
import StarlingPolicy
import Testing

/// What the app wires: the real policy's items for a send it allowed.
let policyItems: DisclosedItemsForSend = { envelope, context in
    try DeterministicPolicyEngine().disclosure(for: OutboundMessage(envelope: envelope, recipientCard: nil, transport: .loopback, context: context)).items
}

actor FailingSink: EgressSink {
    struct Failure: Error {}
    func appendEgress(_ record: EgressRecord, conversation: ConversationID) async throws -> Bool { throw Failure() }
}

@Suite struct EgressRecorderTests {
    struct Phone {
        let store: InMemoryInteractionStore
        let consent: ScriptedConsentProvider
        let recorder: EgressRecorder
        let outbox: Outbox
        let transport: RecordingTransport
    }

    /// Wired as the app wires it: the owner's privacy topics in the real
    /// policy, wrapped by ChainedFromPolicy, and the recorder as observer.
    static func phone(_ interactions: [Interaction], privacy: PrivacySettings = .defaults, consent: ConsentOutcome = .approved,
                      base: (any PolicyEngine)? = nil, items: @escaping DisclosedItemsForSend = policyItems) -> Phone {
        let store = InMemoryInteractionStore(interactions)
        let provider = ScriptedConsentProvider(consent)
        let policy = base ?? DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty, disclosure: privacy.disclosureRules))
        let recorder = EgressRecorder(sink: StoreEgressSink(store: store), itemsForSend: items, now: { Fixtures.date(minutes: 12) })
        let transport = RecordingTransport(localPeer: Fixtures.me)
        let outbox = Outbox(transport: transport, policy: ChainedFromPolicy(wrapping: policy, store: store), consent: provider,
                            observer: recorder, now: { Fixtures.date(minutes: 11) })
        return Phone(store: store, consent: provider, recorder: recorder, outbox: outbox, transport: transport)
    }

    static func placeTerms() throws -> Terms {
        try Terms([
            .place: .places([Fixtures.place()]),
            .budget: .amount(try MoneyAmount(minorUnits: 1200)),
        ])
    }

    @Test func theEgressLogEqualsWhatTheConsentSheetShowed() async throws {
        let plan = try Fixtures.plannedDownFor()
        let link = try KeepItGoingTests.link(after: plan, reaching: [.started])
        let phone = Self.phone([plan, link])
        for friend in [Fixtures.maya, Fixtures.jake] {
            try await phone.outbox.send(.propose(try Proposal(round: 0, terms: Self.placeTerms())), to: friend, conversation: link.conversation,
                                        skill: link.skill, chainedFrom: plan.conversation)
        }
        let sheets = await phone.consent.requests
        #expect(sheets.count == 2)
        let saved = try #require(try await phone.store.interaction(link.id))
        #expect(saved.egress.map(\.items) == sheets.map(\.items))
        #expect(saved.egress.map(\.recipient) == sheets.map(\.recipient))
        #expect(saved.egress.map(\.recipient) == [Fixtures.maya, Fixtures.jake])
        #expect(saved.egress.allSatisfy { $0.at == Fixtures.at(minutes: 12) })
        #expect(saved.egress.first?.topics == [.place, .budget])
        // The parent's own log is untouched.
        #expect(try await phone.store.interaction(plan.id)?.egress.isEmpty == true)
    }

    @Test func aSendAllowedWithoutASheetRecordsThePolicysItems() async throws {
        let plan = try Fixtures.plannedDownFor()
        let phone = Self.phone([plan], base: FixedPolicyEngine(.allow))
        let terms = try Terms([.activity: .keywords([Fixtures.boba]), .time: .slots([Fixtures.tonight])])
        let envelope = try await phone.outbox.send(.propose(try Proposal(round: 0, terms: terms)), to: Fixtures.maya, conversation: plan.conversation, skill: plan.skill)
        let saved = try #require(try await phone.store.interaction(plan.id))
        #expect(saved.egress.map(\.items) == [try policyItems(envelope, .empty)])
        #expect(saved.egress.first?.topics == [.activity, .time])
        #expect(await phone.consent.requests.isEmpty)
    }

    @Test func nothingIsRecordedForADeclinedOrDeniedSend() async throws {
        let plan = try Fixtures.plannedDownFor()
        let link = try KeepItGoingTests.link(after: plan, reaching: [.started])
        let declined = Self.phone([plan, link], consent: .declined)
        await #expect(throws: OutboxError.consentDeclined) {
            try await declined.outbox.send(.propose(try Proposal(round: 0, terms: Self.placeTerms())), to: Fixtures.maya,
                                           conversation: link.conversation, skill: link.skill, chainedFrom: plan.conversation)
        }
        #expect(try await declined.store.interaction(link.id)?.egress.isEmpty == true)

        // Budget set to Never: the policy denies, and the log stays empty.
        let denied = Self.phone([plan, link], privacy: try PrivacySettings([.budget: .never]))
        await #expect(throws: OutboxError.denied(PolicyViolation(rule: PolicyRuleID.never, issue: .budget))) {
            try await denied.outbox.send(.propose(try Proposal(round: 0, terms: Self.placeTerms())), to: Fixtures.maya,
                                         conversation: link.conversation, skill: link.skill, chainedFrom: plan.conversation)
        }
        #expect(try await denied.store.interaction(link.id)?.egress.isEmpty == true)
        #expect(await denied.transport.sent.isEmpty)
    }

    @Test func aSendNoInteractionOwnsIsCountedNotLost() async throws {
        let phone = Self.phone([], base: FixedPolicyEngine(.allow))
        try await phone.outbox.send(.hello(Fixtures.card([SampleSkills.downFor])), to: Fixtures.maya, conversation: ConversationID())
        #expect(await phone.recorder.unattributed == 1)
    }

    @Test func itemsThatCannotBeComputedStillRecordTheSend() async throws {
        struct Unknown: Error {}
        let plan = try Fixtures.plannedDownFor()
        let phone = Self.phone([plan], base: FixedPolicyEngine(.allow), items: { _, _ in throw Unknown() })
        try await phone.outbox.send(.propose(try Proposal(round: 0, terms: Self.placeTerms())), to: Fixtures.maya, conversation: plan.conversation)
        #expect(await phone.recorder.unexplained == 1)
        #expect(try await phone.store.interaction(plan.id)?.egress.map(\.items) == [[]])
    }

    @Test func aFailedWriteIsCounted() async throws {
        let recorder = EgressRecorder(sink: FailingSink(), itemsForSend: policyItems)
        let outbox = Outbox(transport: RecordingTransport(localPeer: Fixtures.me), policy: FixedPolicyEngine(.allow),
                            consent: ScriptedConsentProvider(.approved), observer: recorder)
        try await outbox.send(.propose(try Proposal(round: 0, terms: Self.placeTerms())), to: Fixtures.maya, conversation: ConversationID())
        #expect(await recorder.failedWrites == 1)
    }
}
