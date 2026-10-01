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
        try await oliver.accept(in: conversation)
        await maya.transport.lose(.max) { $0.body.kind == .accept }
        try await maya.accept(in: conversation)
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
            pairedPeers: InMemoryPairedPeerStore(), candidates: StagedCandidates(), maps: FakeMaps(), ownerLimits: { .empty }
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
