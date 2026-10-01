import Foundation
import StarlingChaining
import StarlingCore
import StarlingFakes
import StarlingPolicy
import Testing

/// A policy that allows every send and explains it as the real policy would.
func allowingWithItems() -> FixedPolicyEngine {
    FixedPolicyEngine(.allow, explain: { try! DeterministicPolicyEngine().disclosure(for: $0) })
}

/// A sink over a store that fails on demand: before writing (the store is
/// down) or after writing (the write landed but its answer was lost).
actor FlakySink: EgressSink {
    struct Failure: Error {}
    private let store: StoreEgressSink
    var failBefore = 0
    var failAfter = 0

    init(store: any InteractionStore, failBefore: Int = 0, failAfter: Int = 0) {
        self.store = StoreEgressSink(store: store)
        self.failBefore = failBefore
        self.failAfter = failAfter
    }

    func heal() { failBefore = 0; failAfter = 0 }

    func appendEgress(_ record: EgressRecord, conversation: ConversationID) async throws -> Bool {
        if failBefore > 0 { failBefore -= 1; throw Failure() }
        let found = try await store.appendEgress(record, conversation: conversation)
        if failAfter > 0 { failAfter -= 1; throw Failure() }
        return found
    }
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
                      base: (any PolicyEngine)? = nil) -> Phone {
        let store = InMemoryInteractionStore(interactions)
        let provider = ScriptedConsentProvider(consent)
        let policy = base ?? DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty, disclosure: privacy.disclosureRules))
        let recorder = EgressRecorder(sink: StoreEgressSink(store: store), now: { Fixtures.date(minutes: 12) })
        let transport = RecordingTransport(localPeer: Fixtures.me)
        let outbox = Outbox(transport: transport, policy: ChainedFromPolicy(wrapping: policy, store: store), consent: provider,
                            observer: recorder, now: { Fixtures.date(minutes: 11) })
        return Phone(store: store, consent: provider, recorder: recorder, outbox: outbox, transport: transport)
    }

    /// Venue options and a diet need: Pick a place's Ask me topics. Budget
    /// is Never by default (ADR 0019) and stays on the phone.
    static func placeTerms() throws -> Terms {
        try Terms([
            .place: .places([Fixtures.place()]),
            .diet: .keywords([try Keyword("vegetarian")]),
        ])
    }

    @Test func theEgressLogEqualsWhatTheConsentSheetShowed() async throws {
        let plan = try Fixtures.plannedDownFor()
        let link = try KeepItGoingTests.link(after: plan, reaching: [.started])
        let phone = Self.phone([plan, link])
        for friend in [Fixtures.maya, Fixtures.jake] {
            try await phone.outbox.send(.propose(try Proposal(round: 0, terms: Self.placeTerms())), to: friend, conversation: link.conversation,
                                        skill: link.skill, mode: .invite, chainedFrom: plan.conversation)
        }
        let sheets = await phone.consent.requests
        #expect(sheets.count == 2)
        let saved = try #require(try await phone.store.interaction(link.id))
        #expect(saved.egress.map(\.items) == sheets.map(\.items))
        #expect(saved.egress.map(\.recipient) == sheets.map(\.recipient))
        #expect(saved.egress.map(\.recipient) == [Fixtures.maya, Fixtures.jake])
        #expect(saved.egress.allSatisfy { $0.at == Fixtures.at(minutes: 12) })
        #expect(saved.egress.first?.topics == [.place, .diet])
        // The parent's own log is untouched.
        #expect(try await phone.store.interaction(plan.id)?.egress.isEmpty == true)
    }

    @Test func aSendAllowedWithoutASheetRecordsThePolicysItems() async throws {
        let plan = try Fixtures.plannedDownFor()
        let phone = Self.phone([plan], base: allowingWithItems())
        let terms = try Terms([.activity: .keywords([Fixtures.boba]), .time: .slots([Fixtures.tonight])])
        let envelope = try await phone.outbox.send(.propose(try Proposal(round: 0, terms: terms)), to: Fixtures.maya, conversation: plan.conversation,
                                                   skill: plan.skill, mode: .askQuietly)
        let saved = try #require(try await phone.store.interaction(plan.id))
        let expected = try DeterministicPolicyEngine().disclosure(for: OutboundMessage(envelope: envelope, recipientCard: nil, transport: .loopback)).items
        #expect(saved.egress.map(\.items) == [expected])
        #expect(saved.egress.map(\.message) == [envelope.id])
        #expect(saved.egressIsKnown)
        #expect(saved.egress.first?.topics == [.activity, .time])
        #expect(await phone.consent.requests.isEmpty)
    }

    @Test func nothingIsRecordedForADeclinedOrDeniedSend() async throws {
        let plan = try Fixtures.plannedDownFor()
        let link = try KeepItGoingTests.link(after: plan, reaching: [.started])
        let declined = Self.phone([plan, link], consent: .declined)
        await #expect(throws: OutboxError.consentDeclined) {
            try await declined.outbox.send(.propose(try Proposal(round: 0, terms: Self.placeTerms())), to: Fixtures.maya,
                                           conversation: link.conversation, skill: link.skill, mode: .invite, chainedFrom: plan.conversation)
        }
        #expect(try await declined.store.interaction(link.id)?.egress.isEmpty == true)

        // Diet set to Never: the policy denies, and the log stays empty.
        let denied = Self.phone([plan, link], privacy: try PrivacySettings([.diet: .never]))
        await #expect(throws: OutboxError.denied(PolicyViolation(rule: PolicyRuleID.never, issue: .diet))) {
            try await denied.outbox.send(.propose(try Proposal(round: 0, terms: Self.placeTerms())), to: Fixtures.maya,
                                         conversation: link.conversation, skill: link.skill, mode: .invite, chainedFrom: plan.conversation)
        }
        #expect(try await denied.store.interaction(link.id)?.egress.isEmpty == true)
        #expect(await denied.transport.sent.isEmpty)
    }

    @Test func aSendNoInteractionOwnsIsCountedNotLost() async throws {
        let phone = Self.phone([], base: FixedPolicyEngine(.allow))
        try await phone.outbox.send(.hello(Fixtures.card([SampleSkills.downFor])), to: Fixtures.maya, conversation: ConversationID())
        #expect(await phone.recorder.unattributed == 1)
    }

    @Test func itemsThePolicyCannotExplainStillRecordTheSend() async throws {
        let plan = try Fixtures.plannedDownFor()
        // A policy with no explanation: disclosedItems throws DisclosureUnavailable.
        let phone = Self.phone([plan], base: FixedPolicyEngine(.allow))
        try await phone.outbox.send(.propose(try Proposal(round: 0, terms: Self.placeTerms())), to: Fixtures.maya, conversation: plan.conversation)
        #expect(await phone.recorder.unexplained == 1)
        let saved = try #require(try await phone.store.interaction(plan.id))
        #expect(saved.egress.map(\.items) == [[]])
        #expect(saved.egress.first?.itemsUnknown == true)
        #expect(!saved.egressIsKnown)
        // The audit cannot vouch for this interaction: nothing is claimed
        // as kept, and it says which interaction it could not confirm.
        let whatLeft = WhatLeftYourPhone(interactions: [saved], registry: SampleSkills.registry)
        #expect(whatLeft.kept.isEmpty)
        #expect(whatLeft.unconfirmed == [plan.id])
        #expect(whatLeft.other.isEmpty)
        #expect(whatLeft.sends == 1)
    }

    @Test func aFailedWriteIsKeptAndRetriedUntilItLands() async throws {
        let plan = try Fixtures.plannedDownFor()
        let store = InMemoryInteractionStore([plan])
        let sink = FlakySink(store: store, failBefore: 2)
        let recorder = EgressRecorder(sink: sink)
        let outbox = Outbox(transport: RecordingTransport(localPeer: Fixtures.me), policy: allowingWithItems(),
                            consent: ScriptedConsentProvider(.approved), observer: recorder)
        let terms = try Terms([.budget: .amount(try MoneyAmount(minorUnits: 1200))])
        try await outbox.send(.propose(try Proposal(round: 0, terms: terms)), to: Fixtures.maya, conversation: plan.conversation)

        // The write failed: the log is incomplete, and the audit says so
        // instead of claiming budget stayed on the phone.
        #expect(await recorder.failedWrites == 1)
        #expect(await recorder.unconfirmedConversations == [plan.conversation])
        var whatLeft = WhatLeftYourPhone(interactions: try await store.all(), registry: SampleSkills.registry,
                                         unconfirmed: await recorder.unconfirmedConversations)
        #expect(whatLeft.unconfirmed == [plan.id])
        #expect(whatLeft.kept.isEmpty)
        #expect(whatLeft.shared.isEmpty)

        await recorder.retryPending()
        #expect(await recorder.unconfirmedConversations == [plan.conversation])
        await recorder.retryPending()
        #expect(await recorder.unconfirmedConversations.isEmpty)
        let saved = try #require(try await store.interaction(plan.id))
        #expect(saved.egress.map(\.topics) == [[.budget]])
        whatLeft = WhatLeftYourPhone(interactions: [saved], registry: SampleSkills.registry, unconfirmed: await recorder.unconfirmedConversations)
        #expect(whatLeft.unconfirmed.isEmpty)
        #expect(whatLeft.shared.map(\.topic) == [.budget])
        #expect(whatLeft.kept == [.topic(.time), .topic(.activity), .topic(.place)])
    }

    @Test func aRetryAfterALostAnswerDoesNotRecordTwice() async throws {
        let plan = try Fixtures.plannedDownFor()
        let store = InMemoryInteractionStore([plan])
        let recorder = EgressRecorder(sink: FlakySink(store: store, failAfter: 1))
        let outbox = Outbox(transport: RecordingTransport(localPeer: Fixtures.me), policy: allowingWithItems(),
                            consent: ScriptedConsentProvider(.approved), observer: recorder)
        try await outbox.send(.propose(try Proposal(round: 0, terms: EgressRecorderTests.placeTerms())), to: Fixtures.maya, conversation: plan.conversation)
        #expect(await recorder.unconfirmedConversations == [plan.conversation])
        await recorder.retryPending()
        #expect(await recorder.unconfirmedConversations.isEmpty)
        #expect(try await store.interaction(plan.id)?.egress.count == 1)
    }

    @Test func aNewSendRetriesEarlierFailuresFirst() async throws {
        let plan = try Fixtures.plannedDownFor()
        let store = InMemoryInteractionStore([plan])
        let recorder = EgressRecorder(sink: FlakySink(store: store, failBefore: 1))
        let outbox = Outbox(transport: RecordingTransport(localPeer: Fixtures.me), policy: allowingWithItems(),
                            consent: ScriptedConsentProvider(.approved), observer: recorder)
        let first = try await outbox.send(.propose(try Proposal(round: 0, terms: Terms([.budget: .amount(try MoneyAmount(minorUnits: 1))]))),
                                          to: Fixtures.maya, conversation: plan.conversation)
        try await outbox.send(.propose(try Proposal(round: 0, terms: EgressRecorderTests.placeTerms())), to: Fixtures.jake, conversation: plan.conversation)
        let saved = try #require(try await store.interaction(plan.id))
        #expect(saved.egress.map(\.recipient) == [first.recipient, Fixtures.jake])
        #expect(await recorder.unconfirmedConversations.isEmpty)
    }

    @Test func aFullRetryQueueLeavesTheConversationUnconfirmed() async throws {
        let plan = try Fixtures.plannedDownFor()
        let store = InMemoryInteractionStore([plan])
        let sink = FlakySink(store: store, failBefore: Int.max)
        let recorder = EgressRecorder(sink: sink)
        let outbox = Outbox(transport: RecordingTransport(localPeer: Fixtures.me), policy: allowingWithItems(),
                            consent: ScriptedConsentProvider(.approved), observer: recorder)
        let other = ConversationID()
        try await outbox.send(.propose(try Proposal(round: 0, terms: EgressRecorderTests.placeTerms())), to: Fixtures.maya, conversation: plan.conversation)
        for _ in 0..<EgressRecorder.maxPending {
            try await outbox.send(.propose(try Proposal(round: 0, terms: EgressRecorderTests.placeTerms())), to: Fixtures.maya, conversation: other)
        }
        await sink.heal()
        await recorder.retryPending()
        // The plan's record fell off the queue: it stays unconfirmed for good.
        #expect(await recorder.unconfirmedConversations == [plan.conversation])
        #expect(try await store.interaction(plan.id)?.egress.isEmpty == true)
    }
}
