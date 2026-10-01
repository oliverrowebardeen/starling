import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingTransport
import Synchronization
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

    /// ADR 0011, amendment 14: a send whose step was superseded while it was
    /// in flight reports nothing. Oliver's query to Jake waits on a consent
    /// sheet; meanwhile Maya answers, the answer window closes, and Oliver
    /// proposes. Then the policy recheck denies the old query.
    @Test func aDenialForASupersededStepIsDropped() async throws {
        let quick = PickAPlaceConfiguration(retryInterval: .milliseconds(20), maxRetryInterval: .milliseconds(80),
                                            answerWindow: .milliseconds(400), confirmWindow: .seconds(3))
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let gate = ConsentGate()
        let jakeID = Mutex<PeerID?>(nil)
        let checks = Mutex(0)
        // Queries to Jake: ask on the first check, deny on the recheck.
        let policy = FixedPolicyEngine(decide: { message in
            let envelope = message.envelope
            guard envelope.body.kind == .query, envelope.recipient == jakeID.withLock({ $0 }) else { return .allow }
            let check = checks.withLock { $0 += 1; return $0 }
            return check == 1
                ? .needsConsent(Disclosure(recipient: envelope.recipient, recipientModel: nil, items: [], conversation: envelope.conversation, skill: envelope.skill))
                : .deny(PolicyViolation(rule: "test.never", issue: .place))
        })
        let oliver = Phone("Oliver", hub: hub, maps: maps, policy: policy, gate: gate, configuration: quick)
        let maya = Phone("Maya", hub: hub, maps: maps, configuration: quick)
        let jake = Phone("Jake", hub: hub, maps: maps, configuration: quick)
        jakeID.withLock { $0 = jake.id }
        let group = try await Group([oliver, maya, jake], hub: hub)
        defer { Task { await group.stop() } }

        let request = try await oliver.organize(Venues.all, with: [maya, jake])
        #expect(await eventually { await gate.waiting >= 1 })
        #expect(await eventually { await oliver.coordinator.received.contains { if case .lifecycle(request.id, .proposalReady) = $0 { true } else { false } } })
        await gate.open()
        try await Task.sleep(for: .milliseconds(300))

        #expect(await !oliver.coordinator.received.contains(.lifecycle(request.id, .blockedByPrivacy)))
        #expect(await !group.wire.sent(by: oliver.id).contains { $0.body.kind == .query && $0.recipient == jake.id })
        // The plan goes ahead. Oliver's coordinator refused the proposal
        // while its sheet for the old query was up (a cancelled consent
        // request has no event yet; docs/requests/P15-D.md), so the owner's
        // yes goes to the service directly.
        #expect(await maya.reaches(.proposed, in: request.conversation))
        try await maya.accept(in: request.conversation)
        try await oliver.service.answer(request.id, with: .accept(proposal: 1))
        #expect(await maya.reaches(.planned, in: request.conversation))
        #expect(await oliver.coordinator.received.contains(.lifecycle(request.id, .everyoneConfirmed(revision: 1))))
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
