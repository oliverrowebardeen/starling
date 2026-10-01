import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingTransport
import Testing

/// Withdrawal cancels sends still in flight (Orchestrator rule from the
/// review of lane E's PR).
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
}
