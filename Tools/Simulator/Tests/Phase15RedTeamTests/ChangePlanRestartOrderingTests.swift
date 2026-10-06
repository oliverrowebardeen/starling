import Foundation
import StarlingCore
import Testing

struct ChangePlanRestartOrderingTests {
    @Test func pc42AWithdrawalAcknowledgmentDuringRestoreWaitsForServiceAttachment() async throws {
        let gate = ChangeRecoverySendGate()
        let world = try await ChangeWorld.make(firstObserver: gate)
        defer { Task { await gate.release(); await world.stop() } }
        let a = world.phones[0], b = world.phones[1], c = world.phones[2]
        let before = try await [a.plan(world.origin), b.plan(world.origin), c.plan(world.origin)]
        let change = try await world.start()
        _ = try await a.wait(.confirmed, change.conversation)
        try await b.accept(change.conversation)
        _ = try await c.wait(.proposed, change.conversation)
        await b.relay.drop(.reject)
        await a.service.withdraw(change.id)
        await a.events.record(.lifecycle(change.id, .withdrawn))
        try await P15.eventually("only the lost withdrawal remains") {
            try await a.journal.records().contains {
                if case .withdrawing(let delivery) = $0 { Set(delivery.pending.keys) == [b.id] } else { false }
            }
        }
        let first = try #require(await b.relay.lost.first)
        guard case .reject(let withdrawal) = first.body else { Issue.record("missing lost withdrawal"); return }
        // Force the PC41 interleaving: restore sends, B replies, and the
        // authenticated ack arrives before restore returns and relay attaches.
        await gate.holdWithdrawal(to: b.id)
        let restoring = Task { try await a.restart() }
        defer { restoring.cancel() }
        try await P15.eventually("recovery send held after transport") { await gate.held != nil }
        let resent = try #require(await gate.held)
        try await P15.eventually("acknowledgment authenticated during restore") {
            await a.agent.received.contains { $0.sender == b.id && $0.conversation == resent.conversation && $0.body.kind == .accept }
        }
        let ack = try #require(await a.agent.received.first { $0.sender == b.id && $0.conversation == resent.conversation && $0.body.kind == .accept })
        try await P15.eventually("relay observes recovery acknowledgment") {
            let buffered = await a.relay.buffered.contains(ack)
            let handled = await a.relay.handled.contains(ack.id)
            return buffered || handled
        }
        #expect(ack.body == .accept(Acceptance(proposal: withdrawal.proposal, terms: try Terms([:]))))
        #expect(ack.chainedFrom == world.origin && resent.body == first.body)
        #expect(await a.relay.buffered.contains(ack))
        #expect(await !a.relay.handled.contains(ack.id))
        await gate.release()
        try await restoring.value
        // Attach drains the accepted input. No virtual retry or host sleep
        // is needed for an acknowledgment that already reached the Inbox.
        #expect(await a.relay.buffered.isEmpty)
        #expect(await a.relay.handled.contains(ack.id))
        #expect(try await a.journal.records().allSatisfy { if case .withdrawing = $0 { false } else { true } })
        #expect(await a.sent().filter { $0.body.kind == .reject }.count == 3)
        #expect(world.clock.now == P15.date)
        for (index, phone) in [a, b, c].enumerated() {
            #expect(try await phone.plan(world.origin) == before[index])
            #expect(try await phone.ledger.isRetired(change.conversation))
        }
        await world.checkHealthy()
    }
}
