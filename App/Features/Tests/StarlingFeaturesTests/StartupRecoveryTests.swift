import Foundation
import StarlingChaining
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

/// A journal whose launch read waits until the test opens it, so a test can
/// look at the app while recovery is still under way.
actor GatedJournal: EgressJournal {
    private var entries: [EgressJournalEntry]
    private var opened = false
    private(set) var reading = false

    init(_ entries: [EgressJournalEntry]) { self.entries = entries }

    func open() { opened = true }

    func remember(_ entry: EgressJournalEntry) async throws {
        if let index = entries.firstIndex(where: { $0.message == entry.message }) { entries[index] = entry } else { entries.append(entry) }
    }

    func forget(_ message: MessageID) async throws { entries.removeAll { $0.message == message } }

    func unresolved() async throws -> [EgressJournalEntry] {
        reading = true
        while !opened { try await Task.sleep(for: .milliseconds(1)) }
        return entries
    }
}

/// Counts every call a service gets, to prove none comes before recovery.
actor CountingService: SkillService {
    nonisolated let descriptor = SampleSkills.downFor
    nonisolated let events = AsyncStream<SkillEvent> { _ in }
    private(set) var calls: [String] = []

    func start(_ request: SkillRequest) async throws { calls.append("start") }
    func answer(_ interaction: InteractionID, with answer: OwnerAnswer) async throws { calls.append("answer") }
    func withdraw(_ interaction: InteractionID) async { calls.append("withdraw") }
    func handle(_ event: InboxEvent) async { calls.append("handle") }
    func restore(_ interactions: [Interaction]) async { calls.append("restore") }
    func shutdown() async {}
}

/// Privacy review of PR #73: at launch the journal is recovered after the
/// interactions load and before any service restores, and no audit reads
/// as complete until then.
@MainActor
@Suite struct StartupRecoveryTests {
    let me = PeerID.random()
    let maya = PeerID.random()

    func plannedBoba() throws -> Interaction {
        var item = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(Fixtures.noon))
        let proposal = SkillProposal(revision: 1, participants: [me, maya], terms: try Terms([.activity: .keywords([try Keyword("boba")])]))
        for event: InteractionEvent in [.started, .proposalReady(proposal), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try item.apply(event, at: Timestamp(Fixtures.noon))
        }
        // Ends well after the test, so the plan stays a plan.
        let start = Date().addingTimeInterval(24 * 3600)
        item.record(.plan(try Plan(origin: item.conversation, attendees: Attendees([me, maya]), activity: Keyword("boba"),
                                   time: TimeSlot(start: start, end: start.addingTimeInterval(3600)))))
        return item
    }

    @Test func aRestartRecoversTheJournalBeforeAnyAuditOrServiceWork() async throws {
        let plan = try plannedBoba()
        // The last launch sent the activity and quit before recording it on
        // the interaction: only the journal knows.
        let message = MessageID()
        let record = EgressRecord(at: Timestamp(Fixtures.noon), recipient: maya,
                                  items: [DisclosedItem(category: .terms, issue: .activity, value: .keywords([try Keyword("boba")]))], message: message)
        let journal = GatedJournal([EgressJournalEntry(message: message, conversation: plan.conversation, record: record, sent: true, skilled: true)])
        let service = CountingService()
        var services = AppModelTests.services()
        services.interactions = InMemoryInteractionStore([plan])
        services.egressJournal = journal
        services.makeSkills = { _ in [service] }
        let app = AppModel(services: services)

        let first = Task { await app.start() }
        let secondDone = Box(false)
        let second = Task { await app.start(); secondDone.value = true }
        while await !journal.reading { try await Task.sleep(for: .milliseconds(1)) }

        // Recovery is under way: the interactions are loaded, but no service
        // has been restored or told anything, no audit claims what stayed on
        // the phone, and a second caller is still waiting.
        let loaded = try #require(app.lifecycle.interaction(plan.id))
        #expect(await service.calls.isEmpty)
        let during = app.planDetail(loaded)
        #expect(!during.auditIsComplete)
        #expect(during.kept.isEmpty)
        #expect(!secondDone.value)

        await journal.open()
        await first.value
        await second.value

        #expect(await service.calls.first == "restore")
        let recovered = try #require(app.lifecycle.interaction(plan.id))
        #expect(recovered.egress.map(\.message) == [message])
        let after = app.planDetail(recovered)
        #expect(after.auditIsComplete)
        #expect(!after.shared.isEmpty)
        #expect(!after.kept.contains { $0.localizedCaseInsensitiveContains("activity") })
        await app.shutdown()
    }
}

@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Takes every frame, then, once told to, throws after taking it, as a link
/// that delivered but lost the acknowledgement would.
actor DeliverThenThrowTransport: Transport {
    nonisolated let kind = TransportKind.loopback
    nonisolated let localPeer = PeerID.random()
    nonisolated let events = AsyncStream<TransportEvent> { _ in }
    private(set) var delivered: [Frame] = []
    private var throwAfterDelivery = false

    func failAfterDelivery() { throwAfterDelivery = true }
    func start() async throws {}
    func send(_ frame: Frame, to peer: PeerID) async throws {
        delivered.append(frame)
        if throwAfterDelivery { throw TransportError.peerUnreachable(peer) }
    }
    func stop() async {}
}

/// Focused review of PR #73: audit completeness is live, not a snapshot.
@MainActor
@Suite struct LiveAuditTests {
    let me = PeerID.random()
    let maya = PeerID.random()

    @Test func aSendTheTransportTookAndThenFailedKeepsTheAuditIncomplete() async throws {
        var plan = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(Fixtures.noon))
        let proposal = SkillProposal(revision: 1, participants: [me, maya], terms: try Terms([.activity: .keywords([try Keyword("boba")])]))
        for event: InteractionEvent in [.started, .proposalReady(proposal), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try plan.apply(event, at: Timestamp(Fixtures.noon))
        }
        let start = Date().addingTimeInterval(24 * 3600)
        plan.record(.plan(try Plan(origin: plan.conversation, attendees: Attendees([me, maya]), activity: Keyword("boba"),
                                   time: TimeSlot(start: start, end: start.addingTimeInterval(3600)))))
        let transport = DeliverThenThrowTransport()
        var services = AppModelTests.services()
        services.interactions = InMemoryInteractionStore([plan])
        services.transport = transport
        // A policy that can say what each send discloses: the activity.
        services.makePolicy = { _, _ in
            FixedPolicyEngine(.allow, explain: { message in
                Disclosure(recipient: message.envelope.recipient, recipientModel: nil,
                           items: [DisclosedItem(category: .terms, issue: .activity, value: .keywords([try! Keyword("boba")]))],
                           conversation: message.envelope.conversation, skill: message.envelope.skill)
            })
        }
        let app = AppModel(services: services)
        await app.start()
        let outbox = try #require(app.outbox)
        func detail() throws -> PlanDetail { app.planDetail(try #require(app.lifecycle.interaction(plan.id))) }
        #expect(try detail().auditIsComplete)

        // A send that lands is recorded, and the audit is complete again.
        try await outbox.send(.propose(try Proposal(round: 0, terms: .empty)), to: maya, conversation: plan.conversation)
        await eventually { (try? detail().auditIsComplete) == true && app.lifecycle.interaction(plan.id)?.egress.count == 1 }
        #expect(try detail().auditIsComplete)
        #expect(app.lifecycle.interaction(plan.id)?.egress.count == 1)
        #expect(app.pendingEgress.messages.isEmpty)

        // The link took the frame and then failed: no didSend, no record.
        await transport.failAfterDelivery()
        await #expect(throws: (any Error).self) {
            try await outbox.send(.propose(try Proposal(round: 1, terms: .empty)), to: maya, conversation: plan.conversation)
        }
        #expect(await transport.delivered.count == 2)
        // No refresh needed: the audit reads the live pending sends.
        #expect(try !detail().auditIsComplete)
        #expect(try detail().kept.isEmpty)
        await app.refreshAudit()
        #expect(try !detail().auditIsComplete)
        #expect(try detail().kept.isEmpty)
        await app.shutdown()
    }
}

/// Focused review of PR #73 at 077613a: a skill can answer a friend's
/// request before the coordinator installs it. The send stays pending until
/// its interaction exists and the record is saved, never unattributed.
@MainActor
@Suite struct EarlyAnswerAuditTests {
    @Test func aSendBeforeItsInteractionIsInstalledIsRecordedOnceItIs() async throws {
        let maya = PeerID.random()
        let built = AppModelTests.Built()
        var services = AppModelTests.services(built: built)
        services.makePolicy = { _, _ in
            FixedPolicyEngine(.allow, explain: { message in
                Disclosure(recipient: message.envelope.recipient, recipientModel: nil,
                           items: [DisclosedItem(category: .terms, issue: .activity, value: .keywords([try! Keyword("boba")]))],
                           conversation: message.envelope.conversation, skill: message.envelope.skill)
            })
        }
        let app = AppModel(services: services)
        await app.start()
        let outbox = try #require(app.outbox)
        let down = try #require(built.services.first { $0.descriptor.id == .downFor })

        // The skill answers in a friend's conversation, and only then does
        // the coordinator hear of the request.
        let conversation = ConversationID()
        try await outbox.send(.propose(try Proposal(round: 0, terms: .empty)), to: maya, conversation: conversation, skill: SampleSkills.downFor.ref, mode: .askQuietly)
        #expect(app.pendingEgress.conversations == [conversation])
        #expect(await app.egress.unattributed == 0)
        #expect(await app.egress.waitingForInteraction >= 1)

        let id = InteractionID()
        await down.emit(.incoming(id, conversation: conversation, from: maya, chainedFrom: nil))
        await eventually { app.lifecycle.interaction(id)?.egress.count == 1 }
        let invitee = try #require(app.lifecycle.interaction(id))
        #expect(invitee.egress.count == 1)
        await eventually { app.pendingEgress.messages.isEmpty }
        #expect(app.pendingEgress.messages.isEmpty)
        let detail = app.planDetail(invitee)
        #expect(!detail.shared.isEmpty)
        #expect(!detail.kept.contains { $0.localizedCaseInsensitiveContains("activity") })
        #expect(await app.egress.unattributed == 0)
        await app.shutdown()
    }

    /// Lane E's PR #78, issue #80: a member's send in the starter's
    /// conversation that was journaled but not recorded before a crash lands
    /// on the member's own request at the next launch, by the interaction the
    /// journal kept. One that never reached the transport is recorded as
    /// unknown, so the request's audit claims nothing stayed on the phone.
    @Test(arguments: [true, false])
    func aMembersSendRecoveredAfterACrashLandsOnItsOwnRequest(sent: Bool) async throws {
        let maya = PeerID.random()
        var own = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(Date()))
        try own.apply(.started, at: Timestamp(Date()))
        let startersConversation = ConversationID()
        let message = MessageID()
        let record = EgressRecord(at: Timestamp(Date()), recipient: maya,
                                  items: [DisclosedItem(category: .terms, issue: .activity, value: .keywords([try Keyword("boba")]))], message: message)
        let journal = InMemoryEgressJournal()
        try await journal.remember(EgressJournalEntry(message: message, conversation: startersConversation, record: record,
                                                      sent: sent, skilled: true, interaction: own.id))
        var services = AppModelTests.services()
        services.interactions = InMemoryInteractionStore([own])
        services.egressJournal = journal
        let app = AppModel(services: services)
        await app.start()

        let restored = try #require(app.lifecycle.interaction(own.id))
        #expect(restored.egress.map(\.message) == [message])
        #expect(restored.egress.first?.itemsUnknown == !sent)
        #expect(await app.egress.waitingForInteraction == 0)
        #expect(await app.egress.unconfirmedConversations.isEmpty)
        #expect(try await journal.unresolved().isEmpty)
        if !sent {
            let detail = app.planDetail(restored)
            #expect(!detail.auditIsComplete)
            #expect(detail.kept.isEmpty)
        }
        await app.shutdown()
    }

    /// P15-B request 8 for the audit: a Down for... member's send goes in
    /// the starter's conversation but names its own request, and its record
    /// lands there instead of waiting for an interaction that never comes.
    @Test func aMembersSendInTheStartersConversationIsRecordedOnItsOwnRequest() async throws {
        let maya = PeerID.random()
        var services = AppModelTests.services()
        services.makePolicy = { _, _ in
            FixedPolicyEngine(.allow, explain: { message in
                Disclosure(recipient: message.envelope.recipient, recipientModel: nil,
                           items: [DisclosedItem(category: .terms, issue: .activity, value: .keywords([try! Keyword("boba")]))],
                           conversation: message.envelope.conversation, skill: message.envelope.skill)
            })
        }
        let app = AppModel(services: services)
        await app.start()
        let request = SkillRequest(
            interaction: InteractionID(), conversation: ConversationID(),
            intent: SkillIntent(skill: SampleSkills.downFor.ref, rules: .empty, audience: .picked([maya]), mode: .askQuietly,
                                expiresAt: Timestamp(Date().addingTimeInterval(3600))),
            participants: [maya]
        )
        let own = try await app.lifecycle.start(request, settings: app.settings.skillSettings)

        let startersConversation = ConversationID()
        try await #require(app.outbox).send(.propose(try Proposal(round: 0, terms: .empty)), to: maya, conversation: startersConversation,
                                            context: OutboundContext(interaction: own), skill: SampleSkills.downFor.ref, mode: .askQuietly)
        await eventually { app.lifecycle.interaction(own)?.egress.count == 1 }
        #expect(app.lifecycle.interaction(own)?.egress.count == 1)
        #expect(app.pendingEgress.messages.isEmpty)
        #expect(await app.egress.waitingForInteraction == 0)
        #expect(await app.egress.unattributed == 0)
        await app.shutdown()
    }
}
