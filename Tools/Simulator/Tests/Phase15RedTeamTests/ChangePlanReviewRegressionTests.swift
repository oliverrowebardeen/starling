import Foundation
import StarlingChangePlan
import StarlingCore
import Testing

struct ChangePlanReviewRegressionTests {
    @Test(arguments: [0, 1])
    func pc35AJournaledCommitRecoversBeforeItsPublicationIsPersisted(crashedPhone: Int) async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2]
        let crashed = world.phones[crashedPhone]
        let before = try await crashed.plan(world.origin)
        await crashed.publication.holdCommits()
        // Keep the organizer's durable confirming record until replacement.
        // A recipient's applied receipt is retained even after a successful ack.
        await a.relay.dropConfirmations(2)
        let change = try await world.start()
        try await b.accept(change.conversation)
        try await c.accept(change.conversation)
        try await P15.eventually("commit events awaiting coordinator persistence") {
            await crashed.publication.held.count == 2
        }
        try await P15.eventually("confirmations handled before simulated crash") {
            await a.relay.lost.count == 2
        }
        let records = try await crashed.journal.records()
        #expect(records.contains {
            switch $0 {
            case .confirming(let value): crashedPhone == 0 && value.conversation == change.conversation
            case .applied(let value): crashedPhone == 1 && value.conversation == change.conversation
            default: false
            }
        })
        #expect(try await crashed.plan(world.origin) == before)
        #expect(try await crashed.events.interaction(change.conversation)?.state == .confirmed)
        for phone in [a, b, c] where phone.id != crashed.id {
            try await phone.waitRevision(1, origin: world.origin)
        }
        // Replace only the service, retaining journal and persisted interactions.
        // Discard the old process's unpersisted publications, then drain recovery.
        try await crashed.restart()
        await crashed.stop()
        let recovered = try await crashed.plan(world.origin)
        let expected = try before.updating(activity: .some(ChangeWorld.changedActivity))
        let state = try await crashed.events.interaction(change.conversation)?.state
        withKnownIssue("#119 PC35: durable delivery records do not recover unpublished commits") {
            #expect(recovered == expected)
            #expect(state == .planned)
        }
        await world.checkHealthy()
        await world.stop()
    }

    @Test(arguments: [false, true])
    func pc36ARejoinedFriendCanLeaveAgainWithoutReplayingItsFirstDeparture(restart: Bool) async throws {
        let world = try await ChangeWorld.make()
        let a = world.phones[0], b = world.phones[1], c = world.phones[2]
        _ = try await world.start(.leave, by: 1)
        for phone in [a, c] { try await phone.waitRevision(1, origin: world.origin) }
        let oldNotice = try #require(await b.sent().first { $0.recipient == a.id && $0.body.kind == .propose })
        try await P15.eventually("first leave delivery settled") {
            try await b.journal.records().allSatisfy { if case .leaving = $0 { false } else { true } }
        }
        let rejoin = try await world.start(.change(time: nil, activity: nil, adding: b.id))
        try await c.accept(rejoin.conversation)
        try await b.accept(rejoin.conversation)
        for phone in [a, b, c] {
            try await phone.waitRevision(2, origin: world.origin)
            #expect(try await phone.plan(world.origin).attendees.peers == [a.id, c.id, b.id])
        }
        if restart {
            try await a.restart()
            try await c.restart()
        }
        // The old authenticated notice still cannot undo the agreed rejoin.
        await a.relay.repeatDelivery(oldNotice)
        #expect(try await a.plan(world.origin).revision == 2)
        #expect(try await a.plan(world.origin).attendees.peers.contains(b.id) == true)
        let oldIDs = Set(await b.sent().map(\.id))
        _ = try await world.start(.leave, by: 1)
        let notices = await b.sent().filter { !oldIDs.contains($0.id) && $0.body.kind == .propose }
        #expect(Set(notices.map(\.recipient)) == Set([a.id, c.id]))
        for notice in notices {
            try await world.received(notice, by: notice.recipient == a.id ? 0 : 2)
        }
        // All new notices completed handle. Drain emitted roster updates before
        // asserting absence or presence, instead of waiting for a failing state.
        for phone in [a, c] {
            await phone.stop()
            let remaining = try await phone.plan(world.origin)
            withKnownIssue("#119 PC36: a rejoined friend's second departure is suppressed") {
                #expect(remaining.revision == 3)
                #expect(remaining.attendees.peers == [a.id, c.id])
            }
        }
        await world.checkHealthy()
        await world.stop()
    }
}
