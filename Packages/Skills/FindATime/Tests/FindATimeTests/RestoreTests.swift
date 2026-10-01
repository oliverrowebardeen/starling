@testable import FindATime
import Foundation
import StarlingAvailability
import StarlingAvailabilityFakes
import StarlingCore
import StarlingFakes
import Testing

/// `restore(_:)` after the app is quit and relaunched (ADR 0222).
@Suite(.serialized)
struct RestoreTests {
    @Test func anInviteeResumesItsOpenQuestion() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben", calendar: FakeCalendarStore(status: .denied))
        try await world.start()

        let started = try await a.findATime(with: [b])
        let (asked, question) = try await b.waitForQuestion()
        await b.restart()
        try await b.greetAgain(world)

        try await b.reply(asked, question: question.revision, [question.slots[1]])
        _ = try await a.waitForProposal()
        let (bCard, _) = try await b.waitForProposal()
        try await a.accept(started)
        try await b.accept(bCard)
        try await a.waitForState(started, .planned)
        try await b.waitForState(bCard, .planned)
        #expect(await b.coordinator.rejected.isEmpty)
        await world.stop()
    }

    @Test func aStarterResumesCollectingAnswers() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben")
        let c = world.phone("Cy", calendar: FakeCalendarStore(status: .denied))
        try await world.start()

        let started = try await a.findATime(with: [b, c])
        let (cAsked, question) = try await c.waitForQuestion()
        // Ben has answered; Ana restarts before Cy does.
        try await eventually("Ben answered") { world.envelopes.contains { $0.sender == b.id && $0.body.kind == .answer } }
        await a.restart()
        try await a.greetAgain(world)

        try await c.reply(cAsked, question: question.revision, question.slots)
        let (_, proposal) = try await a.waitForProposal()
        #expect(proposal.plan?.attendees.peers == [a.id, b.id, c.id].sorted())
        await world.stop()
        _ = started
    }

    @Test func aStarterResumesAfterSayingThatWorks() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben")
        try await world.start()

        let started = try await a.findATime(with: [b])
        _ = try await a.waitForProposal()
        let (bCard, _) = try await b.waitForProposal()
        try await a.accept(started)
        try await a.waitForState(started, .confirmed)
        await a.restart()
        try await a.greetAgain(world)

        try await b.accept(bCard)
        try await a.waitForState(started, .planned)
        try await b.waitForState(bCard, .planned)
        await world.stop()
    }

    @Test func aFriendWhoRestartedAfterAcceptingStillGetsThePlan() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben")
        try await world.start()
        // Ana's confirmation is lost while Ben is restarting.
        await a.transport.lose(1) { $0.body.kind == .accept }

        let started = try await a.findATime(with: [b])
        _ = try await a.waitForProposal()
        let (bCard, _) = try await b.waitForProposal()
        try await b.accept(bCard)
        try await b.waitForState(bCard, .confirmed)
        await b.restart()
        try await b.greetAgain(world)
        try await a.accept(started)
        try await a.waitForState(started, .planned)
        try await b.waitForState(bCard, .planned)
        await world.stop()
    }

    @Test func revisionsContinueFromTheStoredOnes() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben")
        let c = world.phone("Cy")
        try await world.start()

        let started = try await a.findATime(with: [b, c])
        _ = try await a.waitForProposal(revision: 1)
        let (bCard, _) = try await b.waitForProposal(revision: 1)
        let (cCard, _) = try await c.waitForProposal(revision: 1)
        await a.restart()
        try await a.greetAgain(world)
        try await c.service.answer(cCard, with: .pass)
        _ = try await a.waitForProposal(revision: 2)
        _ = try await b.waitForProposal(revision: 2)
        try await a.accept(started, revision: 2)
        try await b.accept(bCard, revision: 2)
        try await a.waitForState(started, .planned)
        await world.stop()
    }

    @Test func anInteractionWithNothingToResumeFromIsReportedFailed() async throws {
        let world = World()
        let a = world.phone("Ana")
        try await world.start()
        let orphan = Interaction(skill: FindATimeSkill.ref, role: .invitee, participants: [PeerID.random()], createdAt: Timestamp(Date()))
        try await a.coordinator.begin(orphan)
        await a.service.restore([orphan])
        try await a.waitForState(orphan.id, .ended(.failed))

        // Other skills' interactions are not this service's to touch.
        let other = Interaction(skill: SkillRef(.downFor, SkillVersion(1)), role: .invitee, participants: [PeerID.random()], createdAt: Timestamp(Date()))
        try await a.coordinator.begin(other)
        await a.service.restore([other])
        try await Task.sleep(for: .milliseconds(50))
        #expect(await a.coordinator.interaction(other.id)?.state == .negotiating)
        await world.stop()
    }

    @Test func fileCheckpointsRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("findatime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileFindATimeCheckpoints(directory: directory)
        #expect(try await store.all().isEmpty)

        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben", calendar: FakeCalendarStore(status: .denied))
        try await world.start()
        try await a.findATime(with: [b])
        _ = try await b.waitForQuestion()
        await b.service.flushCheckpoints()
        let saved = try await b.checkpoints.all()
        #expect(saved.count == 1)
        for checkpoint in saved { try await store.save(checkpoint) }
        #expect(try await store.all() == saved)
        try await store.remove(saved[0].interaction)
        #expect(try await store.all().isEmpty)
        await world.stop()
    }
}

/// Crash windows: the service's checkpoint is ahead of the coordinator's
/// store when the app dies between the two writes.
@Suite(.serialized)
struct CrashWindowTests {
    @Test func aCardThatNeverReachedTheStoreIsShownAgain() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben")
        try await world.start()
        let started = try await a.findATime(with: [b])
        let (bCard, _) = try await b.waitForProposal()
        await b.service.flushCheckpoints()

        // Roll Ben's stored interaction back to before the card.
        let stored = await b.coordinator.interaction(bCard)!
        try await b.coordinator.begin(Interaction(
            id: stored.id, conversation: stored.conversation, skill: stored.skill, role: .invitee,
            participants: stored.participants, createdAt: stored.createdAt
        ))
        await b.restart()
        try await b.greetAgain(world)
        _ = try await b.waitForProposal()
        try await b.accept(bCard)
        try await a.accept(started)
        try await b.waitForState(bCard, .planned)
        #expect(await b.coordinator.interaction(bCard)?.plan != nil)
        await world.stop()
    }

    @Test func aPlanThatNeverReachedTheStoreIsRecorded() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben")
        try await world.start()
        let started = try await a.findATime(with: [b])
        _ = try await a.waitForProposal()
        let (bCard, _) = try await b.waitForProposal()
        try await a.accept(started)
        try await b.accept(bCard)
        try await a.waitForState(started, .planned)
        await a.service.flushCheckpoints()

        // Roll Ana's stored interaction back to "That works", before the plan.
        let stored = await a.coordinator.interaction(started)!
        var confirmed = Interaction(id: stored.id, conversation: stored.conversation, skill: stored.skill, role: .initiator,
                                    participants: stored.participants, createdAt: stored.createdAt)
        try confirmed.apply(.started, at: stored.createdAt)
        try confirmed.apply(.proposalReady(stored.proposal!), at: stored.createdAt)
        try confirmed.apply(.ownerAccepted(revision: 1), at: stored.createdAt)
        try await a.coordinator.begin(confirmed)
        await a.restart()
        try await a.waitForState(started, .planned)
        #expect(await a.coordinator.interaction(started)?.plan == stored.plan)
        await world.stop()
    }
}
