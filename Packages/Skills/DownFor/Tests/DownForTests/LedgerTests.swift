import Foundation
@testable import DownFor
import StarlingCore
import StarlingFakes
import StarlingNegotiation
import Testing

/// The conversation ledger (ADR 0021) as Down for... uses it.
@Suite(.timeLimit(.minutes(1))) struct LedgerTests {
    @Test func everyEndingRetiresItsConversation() async throws {
        let world = World(2)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])

        // A starter's withdrawal.
        let mine = try await a.down(for: ["boba"], with: [b])
        let conversation = try #require(await a.lifecycle.interaction(mine)?.conversation)
        await a.service.withdraw(mine)
        try await eventually("A's conversation retired") { (try? await a.ledger.isRetired(conversation)) == true }

        // An invitee's pass.
        _ = try await a.down(for: ["tacos"], with: [b], mode: .invite)
        try await eventually("B's invitation") { await !b.lifecycle.invitations.isEmpty }
        let card = try #require(await b.lifecycle.invitations.first)
        let invitation = try #require(await b.lifecycle.interaction(card)?.conversation)
        try await b.waitForProposal(card)
        try await b.service.answer(card, with: .pass)
        try await eventually("B's invitation retired") { (try? await b.ledger.isRetired(invitation)) == true }

        // A keeps resending the invitation: nothing new opens on B.
        try await Task.sleep(for: .milliseconds(400))
        #expect(await b.lifecycle.invitations == [card])
        await world.expectCleanLifecycles()
    }

    @Test func aRetiredConversationGetsNothing() async throws {
        let world = World(1)
        try await world.start()
        defer { Task { await world.stop() } }
        let b = world["A"]
        let mallory = try Mallory(hub: world.hub)
        try await mallory.start()
        defer { Task { await mallory.stop() } }
        _ = try await b.down(for: ["boba"], with: [], extraParticipants: [mallory.id])

        // Retired on this phone already (an earlier ending, say).
        let conversation = ConversationID()
        try await b.ledger.retire(conversation)
        let tokens = SlotTokenSet(namespace: DownForProfile.namespace, constraints: .empty, now: T.now, expiresAt: T.at(31), timeZone: T.utc)
        let session = try InsecurePSIStub().makeSession(role: .initiator, localSet: tokens.elements, configuration: SlotTokenSet.psiConfiguration())
        guard case .send(let payload) = try await session.start() else { return }
        try await mallory.send(.psi(try PSIFrame(session: UUID(), step: 0, payload: payload)), to: b.id, in: conversation)
        let offer = try Terms([.time: .slots([T.slot(19.5, 20.5)]), .activity: .keywords([T.keyword("boba")])])
        try await mallory.send(.propose(try Proposal(round: 0, terms: offer)), to: b.id, in: conversation, mode: .invite)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await mallory.inbox.envelopes.filter { $0.conversation == conversation }.isEmpty)
        #expect(await b.lifecycle.invitations.isEmpty)
    }

    @Test func aLedgerThatCannotAnswerFailsClosed() async throws {
        let world = World(1)
        try await world.start()
        defer { Task { await world.stop() } }
        let b = world["A"]
        let mallory = try Mallory(hub: world.hub)
        try await mallory.start()
        defer { Task { await mallory.stop() } }
        await b.ledger.failAll()
        let offer = try Terms([.time: .slots([T.slot(19.5, 20.5)]), .activity: .keywords([T.keyword("boba")])])
        try await mallory.send(.propose(try Proposal(round: 0, terms: offer)), to: b.id, in: ConversationID(), mode: .invite)
        try await Task.sleep(for: .milliseconds(300))
        // No card opens when the phone cannot tell whether it ended.
        #expect(await b.lifecycle.invitations.isEmpty)
    }

    /// Lane E's review: an ending is reported only once its conversation is
    /// durably retired, and a retirement that fails is never a clean end.
    @Test func anEndingIsReportedOnlyAfterItsConversationIsRetired() async throws {
        let world = World(2)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        let mine = try await a.down(for: ["boba"], with: [b])
        let conversation = try #require(await a.lifecycle.interaction(mine)?.conversation)
        await a.service.withdraw(mine)
        try await a.waitFor(.ended(.withdrawn), mine)
        // By the time the ending was reported, the ledger already had it.
        #expect(try await a.ledger.isRetired(conversation))
    }

    @Test func aRetirementThatFailsIsReportedAsFailed() async throws {
        let world = World(2)
        try await world.start()
        defer { Task { await world.stop() } }
        let (a, b) = (world["A"], world["B"])
        let mine = try await a.down(for: ["boba"], with: [b])
        await a.ledger.failAll()
        await a.service.withdraw(mine)
        try await a.waitFor(.ended(.failed), mine)
        #expect(await !a.lifecycle.lifecycleEvents.contains(.withdrawn))
        // And nothing in that conversation is answered for the rest of
        // the session, though the ledger could not record it.
        #expect(await a.service.isRetired(try #require(await a.lifecycle.interaction(mine)?.conversation)))
    }
}
