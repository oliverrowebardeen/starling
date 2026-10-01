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
        let journal = GatedJournal([EgressJournalEntry(message: message, conversation: plan.conversation, record: record, sent: true)])
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
