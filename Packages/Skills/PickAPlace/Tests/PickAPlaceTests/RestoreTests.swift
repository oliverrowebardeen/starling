import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingTransport
import Testing

/// `restore(_:)` after the app quits and launches again (ADR 0011).
@Suite("Restore after a restart", .serialized)
struct RestoreTests {
    func oliverAndMaya() async throws -> (Group, oliver: Phone, maya: Phone) {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let maya = Phone("Maya", hub: hub, maps: maps, limits: limits(budget: 20))
        return (try await Group([oliver, maya], hub: hub), oliver, maya)
    }

    @Test func theOrganizerResumesAProposalAfterARestart() async throws {
        let (group, oliver, maya) = try await oliverAndMaya()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))

        await oliver.restart()
        // The card survived; the owner's yes reaches the new service.
        #expect(await oliver.state(in: conversation) == .proposed)
        try await oliver.accept(in: conversation)
        #expect(await oliver.reaches(.planned, in: conversation))
        #expect(await maya.reaches(.planned, in: conversation))
        #expect(await oliver.agreedPlace(in: conversation) == Venues.teaLab.choice)
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aFriendWhoSaidYesSaysItAgainAfterARestart() async throws {
        let (group, oliver, maya) = try await oliverAndMaya()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        // Maya's yes is lost on the way, then her app restarts.
        await maya.transport.lose(.max) { $0.body.kind == .accept }
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))
        await maya.restart()
        await maya.transport.clearRules()

        try await oliver.accept(in: conversation)
        #expect(await oliver.reaches(.planned, in: conversation))
        #expect(await maya.reaches(.planned, in: conversation))
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func bothRestartingStillReachAPlan() async throws {
        let (group, oliver, maya) = try await oliverAndMaya()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        #expect(await oliver.reaches(.proposed, in: conversation))
        try await oliver.accept(in: conversation)
        await maya.transport.lose(.max) { $0.body.kind == .accept }
        try await maya.accept(in: conversation)
        // Both yeses are in each store before the apps quit.
        #expect(await oliver.reaches(.confirmed, in: conversation))
        #expect(await maya.reaches(.confirmed, in: conversation))
        await oliver.restart()
        await maya.restart()
        await maya.transport.clearRules()
        #expect(await oliver.reaches(.planned, in: conversation))
        #expect(await maya.reaches(.planned, in: conversation))
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aFriendStillDecidingResumesWhenAskedAgain() async throws {
        let (group, oliver, maya) = try await oliverAndMaya()
        defer { Task { await group.stop() } }
        // Maya's list is lost, and her app restarts before it goes out again.
        await maya.transport.lose(.max) { $0.body.kind == .answer }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await eventually { await maya.state(in: conversation) == .negotiating })
        await maya.restart()
        await maya.transport.clearRules()
        #expect(await maya.reaches(.proposed, in: conversation))
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aRestoredRequestLooksFactsUpAgainBeforeANewCard() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let maya = Phone("Maya", hub: hub, maps: maps, limits: limits(budget: 20))
        let mallory = Phone("Mallory", hub: hub, maps: maps)
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }
        let skill = PickAPlaceSkill.ref
        let conversation = ConversationID()
        try await mallory.outbox.send(.query(Query(issue: .place, candidates: .places([Venues.bobaGuys.choice]))), to: maya.id,
                                      conversation: conversation, skill: skill, mode: .invite)
        #expect(await eventually { await group.wire.sent(by: maya.id).contains { $0.body.kind == .answer } })
        let first = try Terms([.place: .places([Venues.bobaGuys.choice]), .people: .peers([mallory.id, maya.id])])
        try await mallory.outbox.send(.propose(Proposal(round: 0, terms: first)), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        #expect(await maya.reaches(.proposed, in: conversation))

        // Maya's app restarts, and Maps now prices Boba Guys over her budget.
        await maya.restart()
        await maps.update(candidate("Boba Guys", id: "I.bobaguys", tier: .four, diets: ["vegan"], kinds: ["boba"]))
        let slot = try TimeSlot(start: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_790_003_600))
        let second = try Terms([.place: .places([Venues.bobaGuys.choice]), .people: .peers([mallory.id, maya.id]), .time: .slots([slot])])
        try await mallory.outbox.send(.propose(Proposal(round: 1, terms: second)), to: maya.id, conversation: conversation, skill: skill, mode: .invite)

        // The new card never shows; Mallory gets an ordinary no.
        #expect(await maya.reaches(.ended(.nobodyUp), in: conversation))
        #expect(await maya.interaction(conversation)?.proposal?.terms == first)
        #expect(await eventually { await group.wire.sent(by: maya.id).contains { $0.body.rejection?.reason == .noOverlap } })
    }

    @Test func aWithdrawnRequestStaysClosedAfterARestart() async throws {
        let (group, oliver, maya) = try await oliverAndMaya()
        defer { Task { await group.stop() } }
        // Maya's list and her goodbye are both lost, so Oliver keeps asking.
        await maya.transport.lose(.max) { $0.body.kind == .answer || $0.body.kind == .reject }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.negotiating, in: conversation))
        let id = try #require(await maya.interaction(conversation)?.id)
        await maya.service.withdraw(id)
        #expect(await maya.reaches(.ended(.withdrawn), in: conversation))
        #expect(await eventually { await maya.transport.lost.contains { $0.body.kind == .reject } })

        await maya.restart()
        await maya.transport.clearRules()
        try await Task.sleep(for: .milliseconds(300))
        // Oliver's queries kept coming; Maya's phone sent nothing and
        // opened nothing.
        #expect(await group.wire.sent(to: maya.id).filter { $0.body.kind == .query }.count > 2)
        #expect(await group.wire.sent(by: maya.id).isEmpty)
        #expect(await maya.coordinator.incoming.count == 1)
        #expect(await maya.state(in: conversation) == .ended(.withdrawn))
    }

    @Test func theHourlyLimitSurvivesARestart() async throws {
        let hub = LoopbackHub()
        let maya = Phone("Maya", hub: hub, maps: FakeMaps(Venues.all))
        let mallory = Phone("Mallory", hub: hub, maps: FakeMaps(Venues.all))
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }
        let skill = PickAPlaceSkill.ref
        func probe() async throws {
            let conversation = ConversationID()
            try await mallory.outbox.send(.query(Query(issue: .place, candidates: .places([Venues.bobaGuys.choice]))), to: maya.id,
                                          conversation: conversation, skill: skill, mode: .invite)
            try await Task.sleep(for: .milliseconds(40))
            try await mallory.outbox.send(.reject(Rejection(proposal: MessageID(), reason: .noOverlap)), to: maya.id,
                                          conversation: conversation, skill: skill, mode: .invite)
        }
        for _ in 0..<fastConfiguration.maxNewRequestsPerFriendPerHour { try await probe() }
        try await Task.sleep(for: .milliseconds(100))
        await maya.restart()
        for _ in 0..<3 { try await probe() }
        try await Task.sleep(for: .milliseconds(200))
        let lists = await group.wire.sent(by: maya.id).filter { $0.body.kind == .answer }
        #expect(Set(lists.map(\.conversation)).count == fastConfiguration.maxNewRequestsPerFriendPerHour)
    }

    /// Re-review of PR #55, finding 1: a relaunch never lets a friend ask
    /// about more places in the same conversation.
    @Test func aRelaunchNeverOpensNewCandidates() async throws {
        let hub = LoopbackHub()
        let pho = candidate("Pho Hoa", id: "I.pho", tier: .one, kinds: ["restaurant"])
        let maps = FakeMaps(Venues.all + [pho])
        let maya = Phone("Maya", hub: hub, maps: maps)
        let mallory = Phone("Mallory", hub: hub, maps: maps)
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }
        let skill = PickAPlaceSkill.ref
        let conversation = ConversationID()
        func ask(_ places: [PlaceChoice]) async throws {
            try await mallory.outbox.send(.query(Query(issue: .place, candidates: .places(places))), to: maya.id,
                                          conversation: conversation, skill: skill, mode: .invite)
        }
        let first = [Venues.bobaGuys.choice, Venues.teaLab.choice]
        try await ask(first)
        #expect(await eventually { await group.wire.sent(by: maya.id).contains { $0.body.kind == .answer } })

        for _ in 0..<2 {
            await maya.restart()
            try await ask([Venues.fancy.choice, pho.choice])
            try await Task.sleep(for: .milliseconds(150))
        }
        let answered = await group.wire.sent(by: maya.id).compactMap { envelope -> [PlaceChoice]? in
            if case .answer(let answer) = envelope.body, case .places(let places)? = answer.acceptable { places } else { nil }
        }
        #expect(answered.allSatisfy { Set($0).isSubset(of: first) })
        #expect(try await maya.ledger.answeredCandidates(in: conversation) == Set(first))

        // The same places again are still answered.
        try await ask(first)
        #expect(await eventually { await group.wire.sent(by: maya.id).filter { $0.body.kind == .answer }.count >= 2 })
    }

    @Test func anUnavailableLedgerAnswersNothing() async throws {
        let hub = LoopbackHub()
        let maya = Phone("Maya", hub: hub, maps: FakeMaps(Venues.all))
        let mallory = Phone("Mallory", hub: hub, maps: FakeMaps(Venues.all))
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }
        await maya.ledger.setFailingAnswered(true)
        try await mallory.outbox.send(.query(Query(issue: .place, candidates: .places([Venues.bobaGuys.choice, Venues.fancy.choice]))),
                                      to: maya.id, conversation: ConversationID(), skill: PickAPlaceSkill.ref, mode: .invite)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await group.wire.sent(by: maya.id).isEmpty)
        #expect(await maya.coordinator.incoming.isEmpty)
    }

    @Test func anUnreadableLedgerAdmitsNothing() async throws {
        let hub = LoopbackHub()
        let maya = Phone("Maya", hub: hub, maps: FakeMaps(Venues.all))
        let mallory = Phone("Mallory", hub: hub, maps: FakeMaps(Venues.all))
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }
        await maya.ledger.setFailing(true)
        await maya.restart()
        try await mallory.outbox.send(.query(Query(issue: .place, candidates: .places([Venues.bobaGuys.choice]))), to: maya.id,
                                      conversation: ConversationID(), skill: PickAPlaceSkill.ref, mode: .invite)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await maya.coordinator.incoming.isEmpty)
        #expect(await group.wire.sent(by: maya.id).isEmpty)
    }

    @Test func theAppsAdmissionLogKeepsTheLastHour() async throws {
        let suite = "starling.tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let peer = PeerID.random()
        let now = Date()
        let log = UserDefaultsPickAPlaceLedger(suiteName: suite)
        try await log.recordAdmission(peer, at: now.addingTimeInterval(-4_000))
        try await log.recordAdmission(peer, at: now.addingTimeInterval(-60))
        try await log.recordAdmission(peer, at: now)
        // A new instance reads what the old one wrote, as after a relaunch.
        let reloaded = try await UserDefaultsPickAPlaceLedger(suiteName: suite).admissions(since: now.addingTimeInterval(-3_600))
        #expect(reloaded[peer]?.count == 2)
    }

    @Test func anOrganizerStillAskingIsReportedFailed() async throws {
        let (group, oliver, maya) = try await oliverAndMaya()
        defer { Task { await group.stop() } }
        await oliver.transport.lose(.max) { $0.body.kind == .query }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await oliver.reaches(.negotiating, in: conversation))
        await oliver.restart()
        #expect(await oliver.reaches(.ended(.failed), in: conversation))
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func otherVersionsAndUnknownStepsAreReportedFailed() async throws {
        let service = PickAPlaceService(
            localPeer: .random(), outbox: Outbox(transport: RecordingTransport(), policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved)),
            pairedPeers: InMemoryPairedPeerStore(), candidates: StagedCandidates(), maps: FakeMaps(), ownerLimits: { .empty },
            ledger: InMemoryPickAPlaceLedger()
        )
        let now = Timestamp(Date())
        let otherVersion = Interaction(skill: SkillRef(.pickAPlace, SkillVersion(2, 0)), role: .invitee, participants: [.random()], createdAt: now)
        var askingOwner = Interaction(skill: PickAPlaceSkill.ref, role: .invitee, participants: [.random()], createdAt: now)
        try askingOwner.apply(.ownerNeeded(SkillQuestion(revision: 1, issue: .place, candidates: .places([Venues.bobaGuys.choice]), asker: nil)), at: now)
        let drafting = Interaction(skill: PickAPlaceSkill.ref, role: .initiator, participants: [], createdAt: now)
        let otherSkill = Interaction(skill: SampleSkills.downFor.ref, role: .invitee, participants: [.random()], createdAt: now)

        await service.restore([otherVersion, askingOwner, drafting, otherSkill])
        var reported: [InteractionID] = []
        for await event in service.events {
            if case .lifecycle(let id, .failed) = event { reported.append(id) }
            if reported.count == 2 { break }
        }
        #expect(Set(reported) == [otherVersion.id, askingOwner.id])
    }
}
