import DownFor
import FindATime
import Foundation
import StarlingCore
import StarlingFeatures
import StarlingChaining
import Testing

@MainActor
@Suite("P15-F app durable boundaries", .serialized)
struct AppStorageAndConsentTests {
    func quiet(_ a: AppPhone, _ b: AppPhone) async throws -> Interaction {
        try await a.compose(.downFor, with: [b.id], mode: .askQuietly)
        let id = try #require(await a.app.composer.send())
        return try #require(a.app.lifecycle.interaction(id))
    }

    @Test func cancellingOneOfTwoActualConsentsCannotApproveTheOther() async throws {
        let world = try await AppWorld.make()
        defer { Task { await world.stop() } }
        let (a, b, c) = (world.phones[0], world.phones[1], world.phones[2])
        try await a.compose(.downFor, with: [b.id, c.id], mode: .askQuietly)
        _ = try #require(await a.app.composer.send())
        try await appEventually("both quiet PSI sheets queued") { a.app.consent.waitingCount == 2 }
        let old = try #require(a.app.consent.current)
        let first = try #require(old.disclosure.interaction)
        let conversation = try #require(old.disclosure.conversation)
        await a.app.lifecycle.withdraw(first)
        try await appEventually("cancelled sheet gone, other still open") { a.app.consent.waitingCount == 1 && a.app.consent.current?.id != old.id }
        let next = try #require(a.app.consent.current)
        a.app.consent.answer(.approved, to: old.id)
        #expect(a.app.consent.current?.id == next.id)
        #expect(await a.sent(conversation).isEmpty)
        let other = try #require(next.disclosure.interaction)
        #expect(other != first && a.app.lifecycle.interaction(other)?.pendingConsents.count == 1)
        a.app.consent.answer(.approved, to: next.id)
        try await appEventually("approved second request sent") { await a.wire.records.contains { $0.context.interaction == other && $0.envelope.body.kind == .psi } }
        #expect(a.app.lifecycle.interaction(other)?.pendingConsents.isEmpty == true)
        #expect(a.app.lifecycle.interaction(first)?.egress.isEmpty == true)
    }

    @Test func outstandingConsentIsCancelledAndItsIDCannotReopenAfterDiskReload() async throws {
        let world = try await AppWorld.make(2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        let owner = try await quiet(a, b)
        try await appEventually("consent persisted") { a.app.consent.current != nil }
        await a.app.lifecycle.flush()
        let saved = try #require(await a.store.interaction(owner.id))
        let request = try #require(saved.pendingConsents.first)
        // Snapshot the actual persisted pending state before shutdown can
        // cancel it. Reinstall that snapshot to model the launch boundary.
        await a.outbox.cancelInFlight()
        await a.app.lifecycle.shutdown()
        try await a.store.save(saved)
        try await a.restart()
        let restored = try #require(a.app.lifecycle.interaction(owner.id))
        #expect(restored.pendingConsents.allSatisfy { $0 > request } && restored.consentWatermark >= request)
        #expect(!a.app.lifecycle.consentAnswered(interaction: owner.id, skill: owner.skill,
            conversation: owner.conversation, request: request, approved: true))
        await a.app.lifecycle.flush()
        #expect(try await a.store.interaction(owner.id)?.pendingConsents.contains(request) == false)
        #expect(await a.sent(owner.conversation).isEmpty)
    }

    @Test func stricterSettingsCancelTheInstalledOutboxAfterItsJournalWrite() async throws {
        let world = try await AppWorld.make(2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        await a.app.settings.set(.share, for: .place)
        await a.wire.holdProposal(1)
        let conversation = ConversationID()
        let terms = try Terms([.place: P15.value(.place)])
        let send = Task { try await a.outbox.send(.propose(Proposal(round: 0, terms: terms)), to: b.id,
            conversation: conversation, recipientCard: b.app.agentCard, skill: .init(.pickAPlace, SkillVersion(1)), mode: .invite) }
        try await appEventually("send held after real journal write") { await a.wire.holding }
        #expect(try await a.journal.unresolved().contains { $0.conversation == conversation })
        let card = a.app.agentCard
        await a.app.settings.set(.never, for: .place)
        await a.wire.release()
        await #expect(throws: (any Error).self) { try await send.value }
        #expect(await b.agent.received.filter { $0.conversation == conversation }.isEmpty)
        #expect(await a.sent(conversation).isEmpty)
        #expect(a.app.agentCard == card)
        #expect(a.sequences.highestSent(in: conversation, to: b.id) == nil)
        try await a.restart()
        #expect(a.app.settings.choice(for: .place) == .never)
        await #expect(throws: (any Error).self) {
            try await a.outbox.send(.propose(Proposal(round: 0, terms: terms)), to: b.id,
                conversation: ConversationID(), recipientCard: b.app.agentCard, skill: .init(.pickAPlace, SkillVersion(1)), mode: .invite)
        }
    }

    @Test(arguments: [false, true])
    func interruptedJournalRecoveryKeepsTheOwningRequestsAuditUnknown(memberConversation: Bool) async throws {
        let world = try await AppWorld.make(2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        let approvals = a.approving()
        let owner = try await quiet(a, b)
        try await appEventually("initial PSI send settled") { await a.wire.records.contains { $0.envelope.skill == DownFor.ref } }
        approvals.cancel()
        let conversation = memberConversation ? ConversationID() : owner.conversation
        await a.wire.holdProposal(1)
        let send = Task { try await a.outbox.send(.propose(Proposal(round: 0, terms: Terms([.activity: .keywords([Keyword("boba")])]))),
            to: b.id, conversation: conversation, recipientCard: b.app.agentCard,
            context: OutboundContext(interaction: owner.id), skill: DownFor.ref, mode: .askQuietly) }
        try await appEventually("pending entry on disk") { await a.wire.holding }
        let pending = try #require(await a.journal.unresolved().first { $0.conversation == conversation })
        #expect(pending.interaction == owner.id)
        #expect(!a.app.planDetail(try #require(a.app.lifecycle.interaction(owner.id))).auditIsComplete)
        send.cancel()
        await a.wire.release()
        await #expect(throws: (any Error).self) { try await send.value }
        try await a.restart()
        let restored = try #require(a.app.lifecycle.interaction(owner.id))
        let detail = a.app.planDetail(restored)
        let emptyJournal = try await a.journal.unresolved().isEmpty
        #expect(!detail.auditIsComplete)
        #expect(detail.kept.isEmpty)
        #expect(restored.egress.contains { $0.message == pending.message && $0.itemsUnknown })
        #expect(emptyJournal)
    }

    @Test(arguments: [false, true])
    func globalCancellationReachesConsentAndPreTransportJournalWaits(atJournal: Bool) async throws {
        let world = try await AppWorld.make(2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        if atJournal { await a.app.settings.set(.share, for: .place); await a.wire.holdProposal(1) }
        let conversation = ConversationID()
        let send = Task { try await a.outbox.send(.propose(Proposal(round: 0, terms: Terms([.place: P15.value(.place)]))),
            to: b.id, conversation: conversation, recipientCard: b.app.agentCard,
            skill: .init(.pickAPlace, SkillVersion(1)), mode: .invite) }
        try await appEventually("send is waiting") { if atJournal { await a.wire.holding } else { a.app.consent.current != nil } }
        await a.outbox.cancelInFlight()
        if atJournal {
            await a.wire.release()
            await #expect(throws: (any Error).self) { try await send.value }
            #expect(await b.agent.received.filter { $0.conversation == conversation }.isEmpty)
        } else {
            try await Task.sleep(for: .milliseconds(100))
            #expect(a.app.consent.current == nil)
            await #expect(throws: (any Error).self) { try await send.value }
        }
    }

    @Test(arguments: ["ledger.json", "journal.json", "settings.json", "rules.json"])
    func unreadableInstalledStoresNeverBecomeFreshPermissiveState(name: String) async throws {
        let world = try await AppWorld.make(2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        await a.app.lifecycle.flush()
        try Data("{broken".utf8).write(to: a.file(name).url)
        try await a.restart()
        let conversation = ConversationID()
        await #expect(throws: (any Error).self) {
            try await a.outbox.send(.query(Query(issue: .time, candidates: .slots(AppPhone.slots()))),
                to: b.id, conversation: conversation, recipientCard: b.app.agentCard, skill: FindATimeSkill.ref, mode: .invite)
        }
        #expect(await b.agent.received.filter { $0.conversation == conversation }.isEmpty)
        #expect(a.sequences.highestSent(in: conversation, to: b.id) == nil)
        switch name {
        case "ledger.json": #expect(a.app.ledgerNotice != nil)
        case "journal.json": #expect(a.app.egressJournalUnreadable)
        case "settings.json": #expect(a.app.settings.loadFailed)
        case "rules.json": #expect(a.app.rulesEditor.loadFailed)
        default: Issue.record("Unexpected test store")
        }
    }

    @Test func aFailedRetirementCannotBeShownAsACleanAppWithdrawal() async throws {
        let world = try await AppWorld.make(2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        let query = try Query(issue: .time, candidates: .slots(AppPhone.slots()))
        let sent = try await a.outbox.send(.query(query), to: b.id, conversation: ConversationID(),
            recipientCard: b.app.agentCard, skill: FindATimeSkill.ref, mode: .invite)
        let incoming = try await b.incoming(sent.conversation)
        _ = try await b.wait(.awaitingOwner, incoming.id)
        let path = b.file("ledger.json").url
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        await b.app.lifecycle.withdraw(incoming.id)
        try await appEventually("actual file ledger failure latched") {
            do { _ = try await b.ledger.isRetired(sent.conversation); return false } catch { return true }
        }
        try await Task.sleep(for: .milliseconds(100))
        withKnownIssue("https://github.com/oliverrowebardeen/starling-ios/issues/79") {
            #expect(b.app.lifecycle.interaction(incoming.id)?.state == .ended(.failed))
        }
        #expect(await b.sent(sent.conversation).isEmpty)
    }
}
