import Foundation
import StarlingChangePlan
import StarlingCore
import Testing

struct ChangePlanDeliveryTests {
    private func advance(_ world: ChangeWorld, seconds: TimeInterval) async throws {
        let next = world.clock.now.addingTimeInterval(seconds)
        // The absolute retry must be armed before virtual time moves. Awake
        // host time bounds only this condition, never the protocol deadline.
        try await P15.eventually("reliable-delivery timer registered") { world.clock.deadlines.contains(next) }
        world.clock.advance(to: next)
    }
    private func delivery(_ phone: ChangePhone) async throws -> ConfirmationDelivery? {
        try await phone.journal.records().compactMap { if case .confirming(let value) = $0 { value } else { nil } }.first
    }
    private func agree(_ world: ChangeWorld) async throws -> Interaction {
        let change = try await world.start()
        try await world.phones[1].accept(change.conversation)
        try await world.phones[2].accept(change.conversation)
        _ = try await world.phones[0].wait(.planned, change.conversation)
        return change
    }

    @Test func pc29ADroppedConfirmationIsResentAndAllPlansConverge() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2]
        await b.relay.dropConfirmations()
        let change = try await agree(world)
        try await P15.eventually("one confirmation lost") { await b.relay.lost.count == 1 }
        _ = try await c.wait(.planned, change.conversation)
        #expect(try await b.plan(world.origin).revision == 0)
        try await advance(world, seconds: 5)
        _ = try await b.wait(.planned, change.conversation)
        try await P15.eventually("all confirmation acknowledgments arrive") { try await delivery(a) == nil }
        for phone in [a, b, c] {
            #expect(try await phone.plan(world.origin).revision == 1)
            #expect(try await phone.plan(world.origin).activity == ChangeWorld.changedActivity)
        }
        #expect(await a.sent(change.conversation).filter { $0.recipient == b.id && $0.body.kind == .accept }.count == 2)
        await world.checkHealthy()
        await world.stop()
    }

    @Test(arguments: [false, true])
    func pc30ALostAckAndDuplicateConfirmationApplyOnceAcrossReplacement(restart: Bool) async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2]
        await a.relay.dropConfirmations()
        let change = try await agree(world)
        for phone in [b, c] { _ = try await phone.wait(.planned, change.conversation) }
        try await P15.eventually("exactly one acknowledgment remains") { try await delivery(a)?.pending.count == 1 }
        let lost = try #require(await a.relay.lost.first)
        let peer = try #require(world.phones.first { $0.id == lost.sender })
        let before = try await peer.plan(world.origin)
        if restart {
            try await peer.restart()
            try await a.restart()
        } else {
            try await advance(world, seconds: 5)
        }
        try await P15.eventually("resent confirmation is acknowledged") { try await delivery(a) == nil }
        #expect(try await peer.plan(world.origin) == before)
        let confirmation = try #require(await a.sent(change.conversation).first { $0.recipient == peer.id && $0.body.kind == .accept })
        await peer.relay.repeatDelivery(confirmation)
        #expect(try await peer.plan(world.origin) == before)
        #expect(try await a.ledger.isRetired(change.conversation))
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc31ALostLeaveNoticeReachesTheRemainingPhoneOnRetry() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2]
        await a.relay.drop(.propose)
        _ = try await world.start(.leave, by: 1)
        try await P15.eventually("leave notice lost") { await a.relay.lost.count == 1 }
        try await P15.eventually("other friend observes departure") { try await c.plan(world.origin).revision == 1 }
        #expect(try await a.plan(world.origin).revision == 0)
        try await advance(world, seconds: 5)
        try await P15.eventually("lost departure recovered") { try await a.plan(world.origin).revision == 1 }
        #expect(try await a.plan(world.origin).attendees == c.plan(world.origin).attendees)
        #expect(try await a.plan(world.origin).attendees.peers == [a.id, c.id])
        try await P15.eventually("leave delivery acknowledged") {
            try await b.journal.records().allSatisfy { if case .leaving = $0 { false } else { true } }
        }
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc32AStrangersAckOrConfirmationCannotEndDeliveryOrCommitAPlan() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], x = world.phones[3]
        await b.relay.dropConfirmations()
        let change = try await agree(world)
        try await P15.eventually("confirmation is awaiting B") { try await delivery(a)?.pending.count == 1 }
        let offer = try #require(await world.offers(change.conversation).first { $0.recipient == b.id })
        let empty = MessageBody.accept(Acceptance(proposal: offer.id, terms: try Terms([:])))
        _ = try await x.send(empty, to: a, conversation: change.conversation, parent: world.origin)
        _ = try await x.send(empty, to: b, conversation: change.conversation, parent: world.origin)
        #expect(try await delivery(a)?.pending[b.id] == offer.id)
        #expect(try await b.journal.records().isEmpty)
        try await advance(world, seconds: 5)
        _ = try await b.wait(.planned, change.conversation)
        try await P15.eventually("real friend's acknowledgment settles delivery") { try await delivery(a) == nil }
        await world.checkHealthy()
        await world.stop()
    }
    @Test func pc33ConfirmationRecoveryOutlivesTheOriginalAnswerWindow() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2]
        // Initial confirmation and retries at 5, 15, 35, 75, 155 are lost.
        // The next at 315 must still work: the plan ends at second 3600.
        await b.relay.dropConfirmations(6)
        let change = try await agree(world)
        _ = try await c.wait(.planned, change.conversation)
        var losses = 1
        try await P15.eventually("initial confirmation lost") { await b.relay.lost.count == losses }
        for delay: TimeInterval in [5, 10, 20, 40, 80] {
            try await advance(world, seconds: delay)
            losses += 1
            try await P15.eventually("retry confirmation lost") { await b.relay.lost.count == losses }
        }
        let deadline = P15.date.addingTimeInterval(300)
        // Advance the original window separately from the next retry. This
        // fixes the interleaving instead of racing two newly resumed tasks.
        world.clock.advance(to: deadline)
        // The old implementation expires an accepted voter here. A correct
        // receiver instead retains the accepted session for delivery.
        try await P15.eventually("answer-window timer consumed") { !world.clock.deadlines.contains(deadline) }
        try await advance(world, seconds: 15)
        try await P15.eventually("post-window confirmation delivered") {
            let sends = await a.sent(change.conversation).filter { $0.recipient == b.id && $0.body.kind == .accept }
            guard sends.count == 7, let last = sends.last else { return false }
            return await b.relay.handled.contains(last.id)
        }
        await b.stop()
        let recovered = try await b.plan(world.origin)
        withKnownIssue("#116: an accepted recipient cannot recover after its answer window or restart") {
            #expect(recovered.revision == 1)
            #expect(recovered.activity == ChangeWorld.changedActivity)
        }
        await world.checkHealthy()
        await world.stop()
    }

    @Test func pc34AnAcceptedVoterCanRecoverBeforeItsConfirmationArrives() async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1]
        await b.relay.dropConfirmations()
        let change = try await agree(world)
        try await P15.eventually("first confirmation lost before restart") { await b.relay.lost.count == 1 }
        _ = try await b.wait(.confirmed, change.conversation)
        try await b.restart()
        try await advance(world, seconds: 5)
        try await P15.eventually("confirmation retried after recipient restart") {
            let sends = await a.sent(change.conversation).filter { $0.recipient == b.id && $0.body.kind == .accept }
            guard sends.count == 2, let last = sends.last else { return false }
            return await b.relay.handled.contains(last.id)
        }
        await b.stop()
        let recovered = try await b.plan(world.origin)
        withKnownIssue("#116: an accepted recipient cannot recover after its answer window or restart") {
            #expect(recovered.revision == 1)
            #expect(recovered.activity == ChangeWorld.changedActivity)
        }
        await world.checkHealthy()
        await world.stop()
    }

}
