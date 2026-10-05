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

    /// Final review of PR #55, finding 2: the organizer withdraws while its
    /// confirmation to Maya is held on a consent sheet. The confirmation
    /// never leaves, and Maya's request ends.
    ///
    /// Issue #126: the sheet reaches the coordinator directly, while the
    /// service's "everyone confirmed" comes through its event stream, so
    /// either can arrive first. If the sheet does, the coordinator queues
    /// the plan behind it (ADR 0011, amendment 15) and Oliver's card is on
    /// the sheet rather than planned. Both orders are run, the second one
    /// forced.
    @Test(arguments: [false, true])
    func theOrganizerWithdrawsWhileItsConfirmationIsHeld(sheetFirst: Bool) async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let gate = ConsentGate()
        let askingForConfirmation = FixedPolicyEngine(decide: { message in
            let envelope = message.envelope
            guard envelope.body.kind == .accept else { return .allow }
            return .needsConsent(Disclosure(recipient: envelope.recipient, recipientModel: nil, items: [],
                                            conversation: envelope.conversation, skill: envelope.skill))
        })
        let oliver = Phone("Oliver", hub: hub, maps: maps, policy: askingForConfirmation, gate: gate, configuration: quick)
        let maya = Phone("Maya", hub: hub, maps: maps, configuration: quick)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await oliver.events.release(); await group.stop() } }
        let request = try await oliver.organize(Venues.all, with: [maya])
        for phone in [oliver, maya] { #expect(await phone.reaches(.proposed, in: request.conversation)) }
        try await maya.accept(in: request.conversation)
        if sheetFirst { await oliver.events.hold { if case .lifecycle(_, .everyoneConfirmed) = $0 { true } else { false } } }
        try await oliver.accept(in: request.conversation)

        // Oliver has settled and the confirmation waits on its sheet. His
        // card shows the plan, or the sheet with the plan queued behind it.
        #expect(await eventually { await gate.waiting >= 1 })
        await oliver.events.release()
        #expect(await eventually { await oliver.service.organized[request.conversation]?.phase == .settled })
        let shown = await oliver.state(in: request.conversation)
        #expect(sheetFirst ? shown == .awaitingConsent(resume: .confirmed) : shown == .planned)

        await oliver.service.withdraw(request.id)
        #expect(await oliver.reaches(.ended(.withdrawn), in: request.conversation))
        await gate.open()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await !group.wire.sent(by: oliver.id).contains { $0.body.kind == .accept })
        #expect(await maya.reaches(.ended(.nobodyUp), in: request.conversation))
        #expect(await maya.agreedPlace(in: request.conversation) == nil)
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func theOrganizerCanWithdrawAPlannedPlan() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let request = try await oliver.organize(Venues.all, with: [maya, jake])
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: request.conversation)) }
        for phone in [maya, jake, oliver] { try await phone.accept(in: request.conversation) }
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.planned, in: request.conversation)) }

        await oliver.service.withdraw(request.id)
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.ended(.withdrawn), in: request.conversation), "\(phone.name)") }
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aFriendCanWithdrawFromAPlannedPlan() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation)) }
        for phone in [maya, jake, oliver] { try await phone.accept(in: conversation) }
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.planned, in: conversation)) }

        let jakes = try #require(await jake.interaction(conversation)?.id)
        await jake.service.withdraw(jakes)
        #expect(await jake.reaches(.ended(.withdrawn), in: conversation))
        for phone in [oliver, maya] {
            #expect(await eventually { await phone.attendees(in: conversation) == [oliver.id, maya.id] }, "\(phone.name)")
            #expect(await phone.state(in: conversation) == .planned)
        }
        #expect(await eventually { await jake.service.pendingWithdrawals.isEmpty })
        #expect(await group.lifecyclesWereLegal())
    }

    /// After a relaunch, a friend's phone never answers the organizer's
    /// acknowledgment, so the two phones cannot acknowledge each other
    /// forever.
    @Test func acknowledgmentsAreNeverAcknowledged() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation)) }
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))
        await maya.transport.lose(.max) { $0.body.kind == .reject }
        try await maya.pass(in: conversation)
        #expect(await eventually { await maya.transport.lost.contains { $0.body.kind == .reject } })
        await maya.restart()
        await maya.transport.clearRules()
        #expect(await eventually { await maya.service.pendingWithdrawals.isEmpty })
        try await Task.sleep(for: .milliseconds(300))
        let rejects = await group.wire.envelopes.filter { $0.conversation == conversation && $0.body.kind == .reject }
        #expect(rejects.count < 12)
    }

    /// Final review of PR #55, finding 3: retries after a relaunch still
    /// name the interaction they belong to.
    @Test func restoredRetriesNameTheirInteraction() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation)) }
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))
        let mayas = try #require(await maya.interaction(conversation)?.id)

        await maya.transport.lose(.max) { $0.body.kind == .reject }
        try await maya.pass(in: conversation)
        #expect(await eventually { await maya.transport.lost.contains { $0.body.kind == .reject } })
        await maya.restart()
        await maya.transport.clearRules()
        #expect(await eventually { await maya.service.pendingWithdrawals.isEmpty })

        // The Outbox saw every retry, before and after the relaunch, name
        // Maya's interaction.
        let retries = await maya.sends.records.filter { $0.envelope.body.kind == .reject && $0.envelope.conversation == conversation }
        #expect(retries.count >= 2)
        #expect(retries.allSatisfy { $0.context.interaction == mayas })
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
