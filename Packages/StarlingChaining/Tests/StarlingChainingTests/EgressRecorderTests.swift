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

/// A sink that fails while `failing` is set, and can hold each call at a
/// gate first.
actor GatedSink: EgressSink {
    struct Failure: Error {}
    let gate = Gate()
    private let store: StoreEgressSink
    private var failing: Bool
    private var gated = false

    init(store: any InteractionStore, failing: Bool) {
        self.store = StoreEgressSink(store: store)
        self.failing = failing
    }

    func hold() { gated = true }
    func setFailing(_ value: Bool) { failing = value }

    func appendEgress(_ record: EgressRecord, conversation: ConversationID) async throws -> Bool {
        if gated { await gate.pass() }
        if failing { throw Failure() }
        return try await store.appendEgress(record, conversation: conversation)
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
        let recorder = EgressRecorder(sink: StoreEgressSink(store: store), journal: InMemoryEgressJournal(), now: { Fixtures.date(minutes: 12) })
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
        let recorder = EgressRecorder(sink: sink, journal: InMemoryEgressJournal())
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
        let recorder = EgressRecorder(sink: FlakySink(store: store, failAfter: 1), journal: InMemoryEgressJournal())
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
        let recorder = EgressRecorder(sink: FlakySink(store: store, failBefore: 1), journal: InMemoryEgressJournal())
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
        let recorder = EgressRecorder(sink: sink, journal: InMemoryEgressJournal())
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

    @Test func everyUnresolvedSendStaysUnconfirmedThroughARetry() async throws {
        let first = try Fixtures.plannedDownFor(), second = try Fixtures.plannedDownFor(), third = try Fixtures.plannedDownFor()
        let store = InMemoryInteractionStore([first, second, third])
        let sink = GatedSink(store: store, failing: true)
        let recorder = EgressRecorder(sink: sink, journal: InMemoryEgressJournal())
        let outbox = Outbox(transport: RecordingTransport(localPeer: Fixtures.me), policy: allowingWithItems(),
                            consent: ScriptedConsentProvider(.approved), observer: recorder)
        let offer = MessageBody.propose(try Proposal(round: 0, terms: EgressRecorderTests.placeTerms()))
        // Two sends whose writes failed: both unresolved.
        try await outbox.send(offer, to: Fixtures.maya, conversation: first.conversation)
        try await outbox.send(offer, to: Fixtures.maya, conversation: second.conversation)
        #expect(await recorder.unconfirmedConversations == [first.conversation, second.conversation])

        // The store recovers, but each write is held mid-call.
        await sink.setFailing(false)
        await sink.hold()
        let retrying = Task { await recorder.retryPending() }
        await sink.gate.arrived(1)
        // The first is being written, the second waits its turn: both are
        // still unconfirmed, not only the one in flight.
        #expect(await recorder.unconfirmedConversations == [first.conversation, second.conversation])

        // A new send during the retry is unconfirmed from the moment it is
        // reported, before its own write starts.
        let sending = Task { try await outbox.send(offer, to: Fixtures.maya, conversation: third.conversation) }
        await sink.gate.arrived(2)
        #expect(await recorder.unconfirmedConversations == [first.conversation, second.conversation, third.conversation])

        await sink.gate.open()
        await retrying.value
        _ = try await sending.value
        await recorder.retryPending()
        #expect(await recorder.unconfirmedConversations.isEmpty)
        for plan in [first, second, third] {
            #expect(try await store.interaction(plan.id)?.egress.count == 1)
        }
    }

    /// A plan whose Pick a place link's send failed to record, then the app
    /// quit. `journal` stands in for the file on disk.
    static func failedBeforeRestart() async throws -> (plan: Interaction, link: Interaction, store: InMemoryInteractionStore, journal: InMemoryEgressJournal) {
        let plan = try Fixtures.plannedDownFor()
        let link = try KeepItGoingTests.link(after: plan, reaching: KeepItGoingTests.agreed())
        let store = InMemoryInteractionStore([plan, link])
        let journal = InMemoryEgressJournal()
        let before = EgressRecorder(sink: GatedSink(store: store, failing: true), journal: journal)
        let outbox = Outbox(transport: RecordingTransport(localPeer: Fixtures.me), policy: allowingWithItems(),
                            consent: ScriptedConsentProvider(.approved), observer: before)
        try await outbox.send(.propose(try Proposal(round: 0, terms: placeTerms())), to: Fixtures.maya, conversation: link.conversation,
                              skill: link.skill, mode: .invite, chainedFrom: plan.conversation)
        #expect(await before.unconfirmedConversations == [link.conversation])
        return (plan, link, store, journal)
    }

    @Test func uncertaintySurvivesARestartWhileTheStoreIsStillDown() async throws {
        let (plan, link, store, journal) = try await Self.failedBeforeRestart()
        // Relaunch: the stored link looks complete on its own.
        let stored = try await store.all()
        #expect(try #require(stored.first { $0.id == link.id }).egressIsKnown)
        let after = EgressRecorder(sink: GatedSink(store: store, failing: true), journal: journal)
        // In memory alone, a new recorder knows nothing (the review's case).
        #expect(await after.unconfirmedConversations.isEmpty)
        await after.recover()
        #expect(await after.unconfirmedConversations == [link.conversation])
        // So What left your phone does not claim the link's topics stayed.
        let timeline = try #require(PlanTimeline(for: plan.id, in: stored, registry: SampleSkills.registry,
                                                 unconfirmed: await after.unconfirmedConversations))
        #expect(timeline.whatLeft.unconfirmed == [link.id])
        #expect(!timeline.whatLeft.kept.contains(.topic(.place)))
        #expect(!timeline.whatLeft.kept.contains(.topic(.diet)))
        #expect(try await journal.unresolved().count == 1)
    }

    @Test func aRestartWithTheStoreBackRecordsTheSendOnceAndClearsTheJournal() async throws {
        let (_, link, store, journal) = try await Self.failedBeforeRestart()
        let after = EgressRecorder(sink: GatedSink(store: store, failing: false), journal: journal)
        await after.recover()
        #expect(await after.unconfirmedConversations.isEmpty)
        #expect(try await store.interaction(link.id)?.egress.map(\.topics) == [[.place, .diet]])
        #expect(try await journal.unresolved().isEmpty)
        // Recovering again changes nothing.
        await after.recover()
        #expect(try await store.interaction(link.id)?.egress.count == 1)
    }

    @Test func theJournalHoldsASendBeforeAnyWriteIsAttempted() async throws {
        let plan = try Fixtures.plannedDownFor()
        let store = InMemoryInteractionStore([plan])
        let journal = InMemoryEgressJournal()
        let sink = GatedSink(store: store, failing: false)
        await sink.hold()
        let recorder = EgressRecorder(sink: sink, journal: journal)
        let outbox = Outbox(transport: RecordingTransport(localPeer: Fixtures.me), policy: allowingWithItems(),
                            consent: ScriptedConsentProvider(.approved), observer: recorder)
        let sending = Task { try await outbox.send(.propose(try Proposal(round: 0, terms: EgressRecorderTests.placeTerms())), to: Fixtures.maya,
                                                   conversation: plan.conversation) }
        await sink.gate.arrived()
        // The write is under way; the journal already has the send.
        #expect(try await journal.unresolved().map(\.conversation) == [plan.conversation])
        await sink.gate.open()
        _ = try await sending.value
        #expect(try await journal.unresolved().isEmpty)
    }

    @Test func aJournalThatCannotNoteTheSendStopsIt() async throws {
        let plan = try Fixtures.plannedDownFor()
        let store = InMemoryInteractionStore([plan])
        let journal = InMemoryEgressJournal()
        await journal.failAll()
        let transport = RecordingTransport(localPeer: Fixtures.me)
        let recorder = EgressRecorder(sink: StoreEgressSink(store: store), journal: journal)
        let outbox = Outbox(transport: transport, policy: allowingWithItems(), consent: ScriptedConsentProvider(.approved), observer: recorder)
        await #expect(throws: InMemoryEgressJournal.Unavailable.self) {
            try await outbox.send(.propose(try Proposal(round: 0, terms: EgressRecorderTests.placeTerms())), to: Fixtures.maya, conversation: plan.conversation)
        }
        // Nothing left the phone, and there is nothing to vouch for.
        #expect(await transport.sent.isEmpty)
        #expect(await recorder.unconfirmedConversations.isEmpty)
        #expect(try await store.interaction(plan.id)?.egress.isEmpty == true)
    }

    @Test func aSendCutOffBeforeItWasConfirmedIsUnknownAfterARestart() async throws {
        let plan = try Fixtures.plannedDownFor()
        let link = try KeepItGoingTests.link(after: plan, reaching: KeepItGoingTests.agreed())
        let store = InMemoryInteractionStore([plan, link])
        let journal = InMemoryEgressJournal()
        // The transport fails after willSend, as a crash in between would:
        // didSend never comes.
        let transport = RecordingTransport(localPeer: Fixtures.me)
        await transport.failSends(with: .failed("link dropped"))
        let before = EgressRecorder(sink: StoreEgressSink(store: store), journal: journal)
        let outbox = Outbox(transport: transport, policy: allowingWithItems(), consent: ScriptedConsentProvider(.approved), observer: before)
        await #expect(throws: TransportError.failed("link dropped")) {
            try await outbox.send(.propose(try Proposal(round: 0, terms: EgressRecorderTests.placeTerms())), to: Fixtures.maya,
                                  conversation: link.conversation, skill: link.skill, mode: .invite, chainedFrom: plan.conversation)
        }
        // Noted before the transport, never settled.
        let noted = try await journal.unresolved()
        #expect(noted.map(\.sent) == [false])
        #expect(noted.first?.record.topics == [.place, .diet])
        #expect(await before.unconfirmedConversations == [link.conversation])

        // Relaunch: the note becomes an unknown record on the link itself, so
        // the audit stays honest even without the recorder's memory.
        let after = EgressRecorder(sink: StoreEgressSink(store: store), journal: journal)
        await after.recover()
        let saved = try #require(try await store.interaction(link.id))
        #expect(saved.egress.map(\.itemsUnknown) == [true])
        #expect(!saved.egressIsKnown)
        #expect(try await journal.unresolved().isEmpty)
        let whatLeft = WhatLeftYourPhone(interactions: [plan, saved], registry: SampleSkills.registry)
        #expect(whatLeft.unconfirmed == [link.id])
        #expect(!whatLeft.kept.contains(.topic(.place)) && !whatLeft.kept.contains(.topic(.diet)))
    }

    @Test func aConfirmedSendSettlesItsNoteAndIsKnown() async throws {
        let plan = try Fixtures.plannedDownFor()
        let store = InMemoryInteractionStore([plan])
        let journal = InMemoryEgressJournal()
        let recorder = EgressRecorder(sink: StoreEgressSink(store: store), journal: journal)
        let outbox = Outbox(transport: RecordingTransport(localPeer: Fixtures.me), policy: allowingWithItems(),
                            consent: ScriptedConsentProvider(.approved), observer: recorder)
        let sent = try await outbox.send(.propose(try Proposal(round: 0, terms: EgressRecorderTests.placeTerms())), to: Fixtures.maya,
                                         conversation: plan.conversation)
        let saved = try #require(try await store.interaction(plan.id))
        #expect(saved.egress.map(\.message) == [sent.id])
        #expect(saved.egressIsKnown)
        #expect(try await journal.unresolved().isEmpty)
        #expect(await recorder.unconfirmedConversations.isEmpty)
    }

    /// Lane A's PR #73 race: Pick a place announces an incoming request and
    /// sends its automatic answer before the coordinator has created the
    /// invitee interaction.
    @Test func aSkillSendBeforeItsInteractionExistsWaitsForIt() async throws {
        let store = InMemoryInteractionStore()
        let journal = InMemoryEgressJournal()
        let recorder = EgressRecorder(sink: StoreEgressSink(store: store), journal: journal)
        let outbox = Outbox(transport: RecordingTransport(localPeer: Fixtures.me), policy: allowingWithItems(),
                            consent: ScriptedConsentProvider(.approved), observer: recorder)
        let conversation = ConversationID()
        try await outbox.send(.propose(try Proposal(round: 0, terms: EgressRecorderTests.placeTerms())), to: Fixtures.maya,
                              conversation: conversation, skill: SampleSkills.pickAPlace.ref, mode: .invite)
        // No interaction yet: not dropped as unattributed, still journaled.
        #expect(await recorder.unattributed == 0)
        #expect(await recorder.unconfirmedConversations == [conversation])
        #expect(try await journal.unresolved().map(\.conversation) == [conversation])

        // A restart now keeps it waiting too.
        let after = EgressRecorder(sink: StoreEgressSink(store: store), journal: journal)
        await after.recover()
        #expect(await after.unconfirmedConversations == [conversation])

        // The coordinator catches up and creates the invitee interaction.
        let invitee = Interaction(conversation: conversation, skill: SampleSkills.pickAPlace.ref, role: .invitee,
                                  participants: [Fixtures.maya], createdAt: Fixtures.at(minutes: 1))
        try await store.save(invitee)
        // Before the record lands, the audit claims nothing about Place.
        var whatLeft = WhatLeftYourPhone(interactions: [invitee], registry: SampleSkills.registry, unconfirmed: await after.unconfirmedConversations)
        #expect(whatLeft.unconfirmed == [invitee.id])
        #expect(!whatLeft.kept.contains(.topic(.place)))

        await after.interactionArrived(conversation: conversation)
        #expect(await after.unconfirmedConversations.isEmpty)
        #expect(try await journal.unresolved().isEmpty)
        let saved = try #require(try await store.interaction(invitee.id))
        #expect(saved.egress.map(\.topics) == [[.place, .diet]])
        whatLeft = WhatLeftYourPhone(interactions: [saved], registry: SampleSkills.registry, unconfirmed: await after.unconfirmedConversations)
        #expect(whatLeft.shared.map(\.topic) == [.place, .diet])
        #expect(!whatLeft.kept.contains(.topic(.place)))
    }

    @Test func theNextSendAlsoRetriesARecordWaitingForItsInteraction() async throws {
        let store = InMemoryInteractionStore()
        let recorder = EgressRecorder(sink: StoreEgressSink(store: store), journal: InMemoryEgressJournal())
        let outbox = Outbox(transport: RecordingTransport(localPeer: Fixtures.me), policy: allowingWithItems(),
                            consent: ScriptedConsentProvider(.approved), observer: recorder)
        let conversation = ConversationID()
        let offer = MessageBody.propose(try Proposal(round: 0, terms: EgressRecorderTests.placeTerms()))
        try await outbox.send(offer, to: Fixtures.maya, conversation: conversation, skill: SampleSkills.pickAPlace.ref, mode: .invite)
        try await store.save(Interaction(conversation: conversation, skill: SampleSkills.pickAPlace.ref, role: .invitee,
                                         participants: [Fixtures.maya], createdAt: Fixtures.at(minutes: 1)))
        // Without interactionArrived: the next send in any conversation retries it.
        try await outbox.send(.hello(Fixtures.card([SampleSkills.pickAPlace])), to: Fixtures.jake, conversation: ConversationID())
        #expect(await recorder.unconfirmedConversations.isEmpty)
        #expect(try await store.interaction(conversation: conversation)?.egress.count == 1)
        // The link-level hello, with no skill, is the only unattributed send.
        #expect(await recorder.unattributed == 1)
    }
}
