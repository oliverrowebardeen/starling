import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingTransport
import Testing

/// A yes taken back always reaches the organizer (re-review of PR #55,
/// finding 3).
@Suite("Withdrawals", .serialized)
struct WithdrawalTests {
    let quick = PickAPlaceConfiguration(retryInterval: .milliseconds(20), maxRetryInterval: .milliseconds(80),
                                        answerWindow: .seconds(3), confirmWindow: .milliseconds(600))

    func threeFriends() async throws -> (Group, oliver: Phone, maya: Phone, jake: Phone) {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps, configuration: quick)
        let maya = Phone("Maya", hub: hub, maps: maps, configuration: quick)
        let jake = Phone("Jake", hub: hub, maps: maps, configuration: quick)
        return (try await Group([oliver, maya, jake], hub: hub), oliver, maya, jake)
    }

    /// Maya takes her yes back, but her first rejections are lost, so
    /// Oliver confirms with her in the roster. Her retry arrives after the
    /// confirmation, and the withdrawal wins: Oliver and Jake end up with a
    /// plan for two.
    @Test func aWithdrawalThatCrossesTheConfirmationWins() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation)) }
        try await maya.accept(in: conversation)
        try await jake.accept(in: conversation)
        #expect(await eventually { await oliver.service.organized[conversation]?.accepted == [maya.id, jake.id] })

        await maya.transport.lose(3) { $0.body.kind == .reject }
        try await maya.pass(in: conversation)
        #expect(await maya.reaches(.ended(.withdrawn), in: conversation))
        try await oliver.accept(in: conversation)
        #expect(await oliver.reaches(.planned, in: conversation))

        for phone in [oliver, jake] {
            #expect(await eventually { await phone.attendees(in: conversation) == [oliver.id, jake.id] }, "\(phone.name)")
        }
        #expect(await jake.state(in: conversation) == .planned)
        // Oliver acknowledged, so Maya stopped retrying.
        #expect(await eventually { await maya.service.pendingWithdrawals.isEmpty })
        #expect(await eventually { await (try? maya.ledger.pendingWithdrawals())?.isEmpty == true })
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aWithdrawalSurvivesARestart() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation)) }
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))

        // Every rejection Maya sends is lost until her app restarts.
        await maya.transport.lose(.max) { $0.body.kind == .reject }
        try await maya.pass(in: conversation)
        #expect(await eventually { await maya.transport.lost.contains { $0.body.kind == .reject } })
        #expect(await eventually { await (try? maya.ledger.pendingWithdrawals())?.count == 1 })
        await maya.restart()
        await maya.transport.clearRules()

        try await jake.accept(in: conversation)
        try await oliver.accept(in: conversation)
        #expect(await oliver.reaches(.planned, in: conversation, within: 3))
        for phone in [oliver, jake] {
            #expect(await eventually { await phone.attendees(in: conversation) == [oliver.id, jake.id] }, "\(phone.name)")
        }
        #expect(await eventually { await (try? maya.ledger.pendingWithdrawals())?.isEmpty == true })
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func noRejectionEverNamesAPass() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation)) }
        try await maya.accept(in: conversation)
        try await maya.pass(in: conversation)
        try await jake.pass(in: conversation)
        try await oliver.pass(in: conversation)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await group.wire.envelopes.allSatisfy {
            guard let reason = $0.body.rejection?.reason else { return true }
            return reason == .noOverlap || reason == .expired
        })
    }
}
