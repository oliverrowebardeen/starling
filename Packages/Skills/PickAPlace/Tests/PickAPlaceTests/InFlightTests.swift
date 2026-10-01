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

    /// A denial ends any live step but planned (ADR 0011, amendment 14).
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
        #expect(await maya.reaches(.ended(.blockedByPrivacy), in: conversation))
        #expect(await !group.wire.sent(by: maya.id).contains { $0.body.kind == .accept })
        #expect(await maya.coordinator.received.contains(.lifecycle(id, .blockedByPrivacy)))
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aDeniedProposalIsBlockedByPrivacy() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps, policy: denying(.propose))
        let maya = Phone("Maya", hub: hub, maps: maps)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }

        let request = try await oliver.organize(Venues.all, with: [maya])
        #expect(await oliver.reaches(.ended(.blockedByPrivacy), in: request.conversation))
        #expect(await !group.wire.sent(by: oliver.id).contains { $0.body.kind == .propose })
        // Maya hears "no plan" and nothing else.
        #expect(await maya.reaches(.ended(.nobodyUp), in: request.conversation))
        #expect(await group.lifecyclesWereLegal())
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
        try await Task.sleep(for: .milliseconds(100))
        await gate.open()
        try await Task.sleep(for: .milliseconds(200))

        #expect(await !oliver.coordinator.received.contains(.lifecycle(request.id, .blockedByPrivacy)))
        #expect(await !group.wire.sent(by: oliver.id).contains { $0.body.kind == .query && $0.recipient == jake.id })
        // Cancelling the query closed its sheet (consentCancelled), and the
        // coordinator applied the proposal it had held meanwhile
        // (ADR 0011, amendment 15): the plan goes ahead through the real
        // state machine.
        #expect(await oliver.reaches(.proposed, in: request.conversation))
        #expect(await maya.reaches(.proposed, in: request.conversation))
        for phone in [oliver, maya] { try await phone.accept(in: request.conversation) }
        #expect(await oliver.reaches(.planned, in: request.conversation))
        #expect(await maya.reaches(.planned, in: request.conversation))
        #expect(await group.lifecyclesWereLegal())
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

/// The owner's taps, and proposals that arrive while a send is on its way.
@Suite("Owner taps", .serialized)
struct OwnerTapTests {
    let skill = PickAPlaceSkill.ref

    func askingForYes() -> FixedPolicyEngine {
        FixedPolicyEngine(decide: { message in
            let envelope = message.envelope
            guard envelope.body.kind == .accept else { return .allow }
            return .needsConsent(Disclosure(recipient: envelope.recipient, recipientModel: nil, items: [],
                                            conversation: envelope.conversation, skill: envelope.skill))
        })
    }

    @Test func aDoubleTapSendsOneYes() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let gate = ConsentGate()
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let maya = Phone("Maya", hub: hub, maps: maps, policy: askingForYes(), gate: gate)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))

        let first = Task { try await maya.accept(in: conversation) }
        let second = Task { try await maya.accept(in: conversation) }
        #expect(await eventually { await gate.waiting >= 1 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await gate.waiting == 1)
        await gate.open()
        try await first.value
        try await second.value
        #expect(await maya.reaches(.confirmed, in: conversation))
        let id = try #require(await maya.interaction(conversation)?.id)
        #expect(await maya.coordinator.received.filter { $0 == .lifecycle(id, .ownerAccepted(revision: 1)) }.count == 1)
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func passingAfterSayingYesWithdraws() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let maya = Phone("Maya", hub: hub, maps: maps)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        #expect(await oliver.reaches(.proposed, in: conversation))
        try await maya.accept(in: conversation)
        try await oliver.accept(in: conversation)
        #expect(await oliver.reaches(.planned, in: conversation))

        // A fresh request: both say yes, then the organizer's owner passes.
        let second = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await oliver.reaches(.proposed, in: second))
        try await oliver.accept(in: second)
        #expect(await oliver.reaches(.confirmed, in: second))
        try await oliver.pass(in: second)
        #expect(await oliver.reaches(.ended(.withdrawn), in: second))

        // And a friend who said yes, then passes.
        let third = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.proposed, in: third))
        try await maya.accept(in: third)
        #expect(await maya.reaches(.confirmed, in: third))
        try await maya.pass(in: third)
        #expect(await maya.reaches(.ended(.withdrawn), in: third))
        #expect(await group.lifecyclesWereLegal())
    }

    /// An older proposal whose limits check is still running must not
    /// replace a newer card the owner has already accepted.
    @Test func anOlderProposalResumingLateIsDropped() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let reads = Mutex(0)
        // The first check is the list; the second, for the first proposal,
        // takes 300 ms; later ones are quick.
        let slowSecondRead: @Sendable () async -> ConstraintSet = {
            let read = reads.withLock { $0 += 1; return $0 }
            if read == 2 { try? await Task.sleep(for: .milliseconds(300)) }
            return .empty
        }
        let maya = Phone("Maya", hub: hub, maps: maps, ownerLimits: slowSecondRead)
        let mallory = Phone("Mallory", hub: hub, maps: maps)
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }

        let conversation = ConversationID()
        try await mallory.outbox.send(.query(Query(issue: .place, candidates: .places([Venues.bobaGuys.choice, Venues.teaLab.choice]))),
                                      to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        #expect(await eventually { await group.wire.sent(by: maya.id).contains { $0.body.kind == .answer } })
        let older = try Terms([.place: .places([Venues.teaLab.choice]), .people: .peers([mallory.id, maya.id])])
        let newer = try Terms([.place: .places([Venues.bobaGuys.choice]), .people: .peers([mallory.id, maya.id])])
        try await mallory.outbox.send(.propose(Proposal(round: 0, terms: older)), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        try await mallory.outbox.send(.propose(Proposal(round: 1, terms: newer)), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        #expect(await maya.reaches(.proposed, in: conversation))
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))

        try await Task.sleep(for: .milliseconds(450))
        #expect(await maya.state(in: conversation) == .confirmed)
        #expect(await maya.interaction(conversation)?.proposal?.terms == newer)
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aNewProposalWhileTheYesIsOnItsWayIsIgnored() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let gate = ConsentGate()
        let maya = Phone("Maya", hub: hub, maps: maps, policy: askingForYes(), gate: gate)
        let mallory = Phone("Mallory", hub: hub, maps: maps)
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }

        let conversation = ConversationID()
        try await mallory.outbox.send(.query(Query(issue: .place, candidates: .places([Venues.bobaGuys.choice]))), to: maya.id,
                                      conversation: conversation, skill: skill, mode: .invite)
        #expect(await eventually { await group.wire.sent(by: maya.id).contains { $0.body.kind == .answer } })
        let first = try Terms([.place: .places([Venues.bobaGuys.choice]), .people: .peers([mallory.id, maya.id])])
        try await mallory.outbox.send(.propose(Proposal(round: 0, terms: first)), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        #expect(await maya.reaches(.proposed, in: conversation))

        let tap = Task { try await maya.accept(in: conversation) }
        #expect(await eventually { await gate.waiting >= 1 })
        let slot = try TimeSlot(start: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_790_003_600))
        let second = try Terms([.place: .places([Venues.bobaGuys.choice]), .people: .peers([mallory.id, maya.id]), .time: .slots([slot])])
        try await mallory.outbox.send(.propose(Proposal(round: 1, terms: second)), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        try await Task.sleep(for: .milliseconds(150))
        await gate.open()
        try await tap.value

        #expect(await maya.reaches(.confirmed, in: conversation))
        #expect(await maya.interaction(conversation)?.proposal?.terms == first)
        #expect(await group.lifecyclesWereLegal())
    }
}
