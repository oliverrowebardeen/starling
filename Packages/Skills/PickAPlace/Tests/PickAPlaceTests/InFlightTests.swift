import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingTransport
import Testing

/// Withdrawal cancels sends still in flight, and a policy denial at any
/// live step is reported as blocked by privacy (Orchestrator rules from
/// the review of lane E's PR).
@Suite("Sends in flight", .serialized)
struct InFlightTests {
    /// Asks for consent on every send of the kinds given, and allows the rest.
    func askingFor(_ kinds: Set<MessageBody.Kind>) -> FixedPolicyEngine {
        FixedPolicyEngine(decide: { message in
            let envelope = message.envelope
            guard kinds.contains(envelope.body.kind) else { return .allow }
            return .needsConsent(Disclosure(recipient: envelope.recipient, recipientModel: nil, items: [],
                                            conversation: envelope.conversation, skill: envelope.skill))
        })
    }

    func denying(_ kind: MessageBody.Kind) -> FixedPolicyEngine {
        FixedPolicyEngine(decide: { $0.envelope.body.kind == kind ? .deny(PolicyViolation(rule: "test.never", issue: .people)) : .allow })
    }

    @Test func withdrawingWhileTheOrganizersSheetIsUpSendsNoQuery() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let gate = ConsentGate()
        let oliver = Phone("Oliver", hub: hub, maps: maps, policy: askingFor([.query]), gate: gate)
        let maya = Phone("Maya", hub: hub, maps: maps)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }

        let request = try await oliver.organize(Venues.all, with: [maya])
        #expect(await eventually { await gate.waiting >= 1 })
        await oliver.service.withdraw(request.id)
        await gate.open()
        try await Task.sleep(for: .milliseconds(300))

        #expect(await group.wire.sent(by: oliver.id).allSatisfy { $0.body.kind == .reject })
        #expect(await maya.interaction(request.conversation) == nil)
        #expect(await oliver.reaches(.ended(.withdrawn), in: request.conversation))
    }

    @Test func withdrawingWhileAFriendsSheetIsUpSendsNoList() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let gate = ConsentGate()
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let maya = Phone("Maya", hub: hub, maps: maps, policy: askingFor([.answer]), gate: gate)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }

        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await eventually { await gate.waiting >= 1 })
        let id = try #require(await maya.interaction(conversation)?.id)
        await maya.service.withdraw(id)
        await gate.open()
        try await Task.sleep(for: .milliseconds(300))

        #expect(await !group.wire.sent(by: maya.id).contains { $0.body.kind == .answer })
        #expect(await maya.reaches(.ended(.withdrawn), in: conversation))
    }

    @Test func withdrawingWhileTheYesWaitsOnTheSheetSendsNoAcceptance() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let gate = ConsentGate()
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let maya = Phone("Maya", hub: hub, maps: maps, policy: askingFor([.accept]), gate: gate)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }

        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        let tap = Task { try await maya.accept(in: conversation) }
        #expect(await eventually { await gate.waiting >= 1 })
        let id = try #require(await maya.interaction(conversation)?.id)
        await maya.service.withdraw(id)
        await gate.open()
        try await tap.value
        try await Task.sleep(for: .milliseconds(300))

        #expect(await !group.wire.sent(by: maya.id).contains { $0.body.kind == .accept })
        #expect(await maya.reaches(.ended(.withdrawn), in: conversation))
        #expect(await oliver.agreedPlace(in: conversation) == nil)
    }

    @Test func shutdownCancelsASendWaitingOnTheSheet() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let gate = ConsentGate()
        let oliver = Phone("Oliver", hub: hub, maps: maps, policy: askingFor([.query]), gate: gate)
        let maya = Phone("Maya", hub: hub, maps: maps)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }

        try await oliver.organize(Venues.all, with: [maya])
        #expect(await eventually { await gate.waiting >= 1 })
        await oliver.service.shutdown()
        await gate.open()
        try await Task.sleep(for: .milliseconds(300))
        #expect(await group.wire.sent(by: oliver.id).isEmpty)
    }

    /// Core accepts `.blockedByPrivacy` from every live step but planned
    /// once its pending PR lands; until then the state machine refuses it
    /// from proposed, so these tests check what the service reported.
    @Test func aDeniedYesIsBlockedByPrivacy() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let maya = Phone("Maya", hub: hub, maps: maps, policy: denying(.accept))
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }

        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        let id = try #require(await maya.interaction(conversation)?.id)
        try await maya.accept(in: conversation)
        #expect(await eventually { await maya.coordinator.received.contains(.lifecycle(id, .blockedByPrivacy)) })
        #expect(await !group.wire.sent(by: maya.id).contains { $0.body.kind == .accept })
    }

    @Test func aDeniedProposalIsBlockedByPrivacy() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps, policy: denying(.propose))
        let maya = Phone("Maya", hub: hub, maps: maps)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }

        let request = try await oliver.organize(Venues.all, with: [maya])
        #expect(await eventually { await oliver.coordinator.received.contains(.lifecycle(request.id, .blockedByPrivacy)) })
        #expect(await !group.wire.sent(by: oliver.id).contains { $0.body.kind == .propose })
        // Maya hears "no plan" and nothing else.
        #expect(await maya.reaches(.ended(.nobodyUp), in: request.conversation))
    }

    @Test func aDeclinedSheetAddsNoEventFromTheService() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps, policy: askingFor([.query]), consent: .declined)
        let maya = Phone("Maya", hub: hub, maps: maps)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }

        let request = try await oliver.organize(Venues.all, with: [maya])
        #expect(await oliver.reaches(.ended(.declined), in: request.conversation))
        try await Task.sleep(for: .milliseconds(100))
        let fromService = await oliver.coordinator.received.filter { if case .lifecycle(request.id, _) = $0 { true } else { false } }
        // Only the coordinator's own .started; the pass came from the sheet.
        #expect(fromService == [.lifecycle(request.id, .started)])
        #expect(await group.lifecyclesWereLegal())
    }
}
