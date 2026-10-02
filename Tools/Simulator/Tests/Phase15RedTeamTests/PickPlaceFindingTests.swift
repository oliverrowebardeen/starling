import Foundation
import PickAPlace
import SimulatorKit
import StarlingCore
import StarlingFakes
import Testing

@Suite("P15-F Pick a place finding reproductions", .serialized)
struct PickPlaceFindingTests {
    @Test func anAnswerMustNameAQueryTheOrganizerActuallySent() async throws {
        let world = try await PlaceWorld.make(count: 2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        await b.relay.attach(nil)
        let candidate = try PlaceWorld.candidate()
        let request = try await a.organize([candidate], participants: [b.id])
        try await Simulation.eventually("organizer query delivered") {
            await b.agent.received.contains { $0.conversation == request.conversation && $0.body.kind == .query }
        }
        let queries = await b.agent.received.filter { $0.conversation == request.conversation }
        let invented = MessageID()
        #expect(queries.allSatisfy { $0.id != invented })
        let query = try Query(issue: .place, candidates: .places([candidate.choice]))
        let answer = try Answer(query: invented, issue: .place, status: .answered, acceptable: .places([candidate.choice]))
        let forged = try await b.send(.answer(answer), to: a.id, conversation: request.conversation, context: OutboundContext(answering: query))
        try await world.delivered(forged, to: a)
        let proposed = try await a.events.interaction(request.conversation)?.proposal
        #expect(proposed == nil)
        // A genuine answer is the control, and should be the first to propose.
        let genuine = try #require(queries.first { $0.body.kind == .query })
        let good = try Answer(query: genuine.id, issue: .place, status: .answered, acceptable: .places([candidate.choice]))
        _ = try await b.send(.answer(good), to: a.id, conversation: request.conversation, context: OutboundContext(answering: query))
        _ = try await a.wait(.proposed, in: request.conversation)
    }

    @Test func anOpenConversationStillRejectsAnIncompatibleSkillMajor() async throws {
        let world = try await PlaceWorld.make(count: 2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        let candidate = try PlaceWorld.candidate()
        await world.seed([candidate])
        let suite = PickPlaceIntegrationTests()
        let invite = try await suite.open(world, [candidate])
        let incompatible = SkillRef(PickAPlaceSkill.ref.id, SkillVersion(2, 0))
        let bad = try await a.send(.propose(suite.offer(candidate, from: a, to: b)), to: b.id,
            conversation: invite.conversation, skill: incompatible)
        try await world.delivered(bad, to: b)
        let proposed = try await b.events.interaction(invite.conversation)?.proposal
        #expect(proposed == nil)
        // A fresh incompatible query already fails closed.
        let fresh = ConversationID()
        let incompatibleQuery = try await a.send(.query(suite.query([candidate])), to: b.id, conversation: fresh, skill: incompatible)
        try await world.delivered(incompatibleQuery, to: b)
        #expect(try await b.events.interaction(fresh) == nil)
        #expect(await b.sent(fresh).isEmpty)
        let compatible = try await a.send(.propose(suite.offer(candidate, from: a, to: b)), to: b.id,
            conversation: invite.conversation)
        try await world.delivered(compatible, to: b)
        _ = try await b.wait(.proposed, in: invite.conversation)
    }

    @Test func aFailedAdmissionWriteCannotResetTheProbeLimitAfterRestart() async throws {
        let ledger = FailedAdmissionLedger()
        let world = try await PlaceWorld.make(count: 2, inviteeLedger: ledger)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        await a.relay.attach(nil)
        let candidate = try PlaceWorld.candidate()
        await world.seed([candidate])
        var conversations: [ConversationID] = []
        for _ in 0..<5 {
            let conversation = ConversationID()
            conversations.append(conversation)
            let sent = try await a.send(.query(PickPlaceIntegrationTests().query([candidate])), to: b.id, conversation: conversation)
            try await world.delivered(sent, to: b)
            try await b.restart()
        }
        #expect(await ledger.attempts == 5)
        #expect(try await ledger.admissions(since: .distantPast).isEmpty)
        let sent = await b.observer.records.map(\.envelope).filter { conversations.contains($0.conversation) }
        #expect(sent.isEmpty)
        #expect(await b.maps.lookedUp.isEmpty)
        for conversation in conversations {
            #expect(try await b.conversations.isRetired(conversation))
            #expect(try await b.events.interaction(conversation) == nil)
        }
    }
}

/// A throwing production dependency contract, with only admission writes
/// failing. No successful persistence is implied by a thrown write.
actor FailedAdmissionLedger: PickAPlaceLedger {
    let base = InMemoryPickAPlaceLedger()
    private(set) var attempts = 0
    func admissions(since date: Date) async throws -> [PeerID: [Date]] { try await base.admissions(since: date) }
    func recordAdmission(_ peer: PeerID, at date: Date) async throws { attempts += 1; throw LedgerUnavailable() }
    func pendingWithdrawals() async throws -> [PendingWithdrawal] { try await base.pendingWithdrawals() }
    func recordWithdrawal(_ withdrawal: PendingWithdrawal) async throws { try await base.recordWithdrawal(withdrawal) }
    func clearWithdrawal(_ conversation: ConversationID) async throws { try await base.clearWithdrawal(conversation) }
    func deadlines(for conversation: ConversationID) async throws -> RequestDeadlines? { try await base.deadlines(for: conversation) }
    func recordDeadlines(_ deadlines: RequestDeadlines, for conversation: ConversationID) async throws { try await base.recordDeadlines(deadlines, for: conversation) }
}
