@testable import FindATime
import Foundation
import StarlingAvailability
import StarlingAvailabilityFakes
import StarlingCore
import StarlingFakes
import Synchronization
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

        // From 2 PM, so the clock moves below stay before the proposed time.
        let started = try await a.findATime(with: [b, c], range: [T.slot(14, 24)])
        _ = try await a.waitForProposal(revision: 1)
        let (bCard, _) = try await b.waitForProposal(revision: 1)
        let (cCard, _) = try await c.waitForProposal(revision: 1)
        try await b.accept(bCard, revision: 1)
        try await eventually("Ben's acceptance reached Ana") { world.envelopes.contains { $0.sender == b.id && $0.body.kind == .accept } }
        await a.restart()
        try await a.greetAgain(world)
        try await c.service.answer(cCard, with: .pass)
        world.clock.advance(hours: 2)
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
        await a.coordinator.begin(orphan)
        await a.service.restore([orphan])
        try await a.waitForState(orphan.id, .ended(.failed))

        // Other skills' interactions are not this service's to touch.
        let other = Interaction(skill: SkillRef(.downFor, SkillVersion(1)), role: .invitee, participants: [PeerID.random()], createdAt: Timestamp(Date()))
        await a.coordinator.begin(other)
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
        await b.coordinator.begin(Interaction(
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
        await a.coordinator.begin(confirmed)
        await a.restart()
        try await a.waitForState(started, .planned)
        #expect(await a.coordinator.interaction(started)?.plan == stored.plan)
        await world.stop()
    }

    /// Review of PR #53, finding 2 (invitee): Ben's checkpoint has
    /// proposal 2, but the store still has his "That works" for proposal 1.
    /// The acceptance must not move to proposal 2: the card is shown again.
    @Test func anAcceptanceNeverMovesToANewerProposalOnRestore() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben")
        let c = world.phone("Cy")
        try await world.start()
        // From 2 PM, so the clock moves below stay before the proposed time.
        let started = try await a.findATime(with: [b, c], range: [T.slot(14, 24)])
        let (bCard, first) = try await b.waitForProposal(revision: 1)
        let (cCard, _) = try await c.waitForProposal(revision: 1)
        try await b.accept(bCard, revision: 1)
        try await c.service.answer(cCard, with: .pass)
        try await eventually("Ben's acceptance reached Ana") { world.envelopes.contains { $0.sender == b.id && $0.body.kind == .accept } }
        world.clock.advance(hours: 2)
        let (_, second) = try await b.waitForProposal(revision: 2)
        await b.service.flushCheckpoints()

        let stored = await b.coordinator.interaction(bCard)!
        var rolledBack = Interaction(id: stored.id, conversation: stored.conversation, skill: stored.skill, role: .invitee,
                                     participants: stored.participants, createdAt: stored.createdAt)
        try rolledBack.apply(.proposalReady(first), at: stored.createdAt)
        try rolledBack.apply(.ownerAccepted(revision: 1), at: stored.createdAt)
        await b.coordinator.begin(rolledBack)
        let acceptancesBefore = world.envelopes.filter { $0.sender == b.id && $0.body.kind == .accept }.count
        await b.restart()
        try await b.greetAgain(world)

        _ = try await b.waitForProposal(revision: 2)
        try await Task.sleep(for: .milliseconds(100))
        // Nothing accepted proposal 2 on Ben's behalf.
        let acceptances = world.envelopes.filter { $0.sender == b.id && $0.body.kind == .accept }
        #expect(acceptances.count == acceptancesBefore)
        #expect(!acceptances.contains { if case .accept(let a) = $0.body { a.terms == second.terms } else { false } })

        try await b.accept(bCard, revision: 2)
        try await a.accept(started, revision: 2)
        try await b.waitForState(bCard, .planned)
        await world.stop()
    }

    /// Finding 2 (starter): Ana's checkpoint has proposal 2, the store her
    /// "That works" for proposal 1. Her card is shown again and nothing is
    /// confirmed until she says yes to proposal 2.
    @Test func theStartersAcceptanceNeverMovesToANewerProposalOnRestore() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben")
        let c = world.phone("Cy")
        try await world.start()
        // From 2 PM, so the clock moves below stay before the proposed time.
        let started = try await a.findATime(with: [b, c], range: [T.slot(14, 24)])
        let (_, first) = try await a.waitForProposal(revision: 1)
        let (bCard, _) = try await b.waitForProposal(revision: 1)
        let (cCard, _) = try await c.waitForProposal(revision: 1)
        try await a.accept(started, revision: 1)
        try await b.accept(bCard, revision: 1)
        try await c.service.answer(cCard, with: .pass)
        try await eventually("Ben's acceptance reached Ana") { world.envelopes.contains { $0.sender == b.id && $0.body.kind == .accept } }
        world.clock.advance(hours: 2)
        _ = try await a.waitForProposal(revision: 2)
        await a.service.flushCheckpoints()

        let stored = await a.coordinator.interaction(started)!
        var rolledBack = Interaction(id: stored.id, conversation: stored.conversation, skill: stored.skill, role: .initiator,
                                     participants: stored.participants, createdAt: stored.createdAt)
        try rolledBack.apply(.started, at: stored.createdAt)
        try rolledBack.apply(.proposalReady(first), at: stored.createdAt)
        try rolledBack.apply(.ownerAccepted(revision: 1), at: stored.createdAt)
        await a.coordinator.begin(rolledBack)
        await a.restart()
        try await a.greetAgain(world)

        _ = try await a.waitForProposal(revision: 2)
        try await b.accept(bCard, revision: 2)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await a.coordinator.interaction(started)?.state == .proposed)
        #expect(await b.coordinator.interaction(bCard)?.state == .confirmed)
        try await a.accept(started, revision: 2)
        try await a.waitForState(started, .planned)
        try await b.waitForState(bCard, .planned)
        await world.stop()
    }

    /// Finding 4: a restart while the confirmations are still waiting on a
    /// consent sheet is not a plan. The confirmations go out through Outbox
    /// after the restart, with a fresh sheet, and only then is it a plan.
    @Test func aRestartBeforeTheConfirmationsLeftIsNotAPlan() async throws {
        let world = World()
        let sheet = HeldConsent()
        let a = world.phone("Ana", policy: FixedPolicyEngine(decide: { message in
            guard case .accept = message.envelope.body else { return .allow }
            return .needsConsent(Disclosure(recipient: message.envelope.recipient, recipientModel: nil, items: [],
                                            conversation: message.envelope.conversation, skill: message.envelope.skill, interaction: message.context.interaction))
        }), consent: sheet)
        let b = world.phone("Ben")
        try await world.start()
        let started = try await a.findATime(with: [b])
        _ = try await a.waitForProposal()
        let (bCard, _) = try await b.waitForProposal()
        try await a.accept(started)
        try await b.accept(bCard)
        try await eventually("the confirmation's sheet is open") { await sheet.asked == 1 }
        await a.service.flushCheckpoints()

        await a.restart()
        try await a.greetAgain(world)
        try await eventually("a fresh sheet after the restart") { await sheet.asked == 2 }
        #expect(await a.coordinator.interaction(started)?.state == .awaitingConsent(resume: .confirmed))
        #expect(!world.envelopes.contains { $0.sender == a.id && $0.body.kind == .accept })

        await sheet.answerAll(.approved)
        try await a.waitForState(started, .planned)
        try await b.waitForState(bCard, .planned)
        await world.stop()
    }

    /// Finding 5: a conversation that ended before a restart stays ended.
    /// A late query for it gets "no plan", never a new card.
    @Test func anEndedConversationStaysEndedAfterARestart() async throws {
        let world = World()
        let mallory = world.phone("Mallory")
        let target = world.phone("Ben", calendar: FakeCalendarStore(status: .denied))
        try await world.start()
        let conversation = ConversationID()
        let query = MessageBody.query(try Query(issue: .time, candidates: .slots([T.slot(9, 10)])))
        try await mallory.send(query, to: target, conversation: conversation)
        let (asked, _) = try await target.waitForQuestion()
        try await target.service.answer(asked, with: .pass)
        try await target.waitForState(asked, .ended(.declined))

        await target.restart()
        try await target.greetAgain(world)
        try await mallory.send(query, to: target, conversation: conversation)
        try await eventually("the late query handled") {
            await target.service.diagnostics.ignored["query for an ended conversation", default: 0] == 1
        }
        // No new card, and no reply at all.
        #expect(!world.envelopes.contains { $0.sender == target.id && $0.skill != nil })
        let cards = await target.coordinator.all()
        #expect(cards.count == 1)
        #expect(cards.first?.state == .ended(.declined))
        await world.stop()
    }

    /// Lane E's review (ADR 0021): an ending is reported only after the
    /// conversation's retirement is recorded in the ledger.
    @Test func anEndingIsReportedOnlyOnceRetired() async throws {
        let world = World()
        let a = world.phone("Ana")
        let controlled = Mutex<ControlledLedger?>(nil)
        let b = world.phone("Ben", calendar: FakeCalendarStore(status: .denied), ledger: { inner in
            let ledger = ControlledLedger(inner)
            controlled.withLock { $0 = ledger }
            return ledger
        })
        let ledger = controlled.withLock { $0! }
        try await world.start()
        try await a.findATime(with: [b])
        let (asked, _) = try await b.waitForQuestion()
        let conversation = await b.coordinator.interaction(asked)!.conversation

        await ledger.hold()
        try await b.service.answer(asked, with: .pass)
        try await eventually("retiring") { await ledger.retireCalls == 1 }
        try await Task.sleep(for: .milliseconds(60))
        // Not retired yet, so not reported yet.
        #expect(await b.coordinator.interaction(asked)?.state == .awaitingOwner)
        #expect(!(await b.coordinator.log.contains { if case .lifecycle(_, .ownerPassed) = $0 { true } else { false } }))

        await ledger.release()
        try await b.waitForState(asked, .ended(.declined))
        #expect(try await b.conversations.isRetired(conversation))
        await world.stop()
    }

    /// If retiring throws, the ending is not reported as clean: the
    /// interaction ends failed, the conversation stays closed to a fresh
    /// request, and the next launch retires it.
    @Test func aFailedRetirementReportsFailedAndStaysClosed() async throws {
        let world = World()
        let mallory = world.phone("Mallory")
        let controlled = Mutex<ControlledLedger?>(nil)
        let b = world.phone("Ben", calendar: FakeCalendarStore(status: .denied), ledger: { inner in
            let ledger = ControlledLedger(inner)
            controlled.withLock { $0 = ledger }
            return ledger
        })
        let ledger = controlled.withLock { $0! }
        try await world.start()
        let conversation = ConversationID()
        let query = MessageBody.query(try Query(issue: .time, candidates: .slots([T.slot(9, 10)])))
        try await mallory.send(query, to: b, conversation: conversation)
        let (asked, _) = try await b.waitForQuestion()

        await ledger.failRetirements(true)
        try await b.service.answer(asked, with: .pass)
        try await b.waitForState(asked, .ended(.failed))
        #expect(try await b.conversations.isRetired(conversation) == false)

        // A fresh request in the same conversation opens nothing.
        try await mallory.send(query, to: b, conversation: conversation)
        try await Task.sleep(for: .milliseconds(60))
        #expect(await b.coordinator.all().count == 1)

        // The next launch retires it, and reports nothing more.
        await ledger.failRetirements(false)
        await b.restart()
        try await eventually("retired on relaunch") { (try? await b.conversations.isRetired(conversation)) == true }
        #expect(await b.coordinator.rejected.isEmpty)
        await world.stop()
    }

    /// A crash between the ending and its retirement: the next launch
    /// retires the conversation and only then reports the ending.
    @Test func aCrashBeforeRetirementIsFinishedOnRelaunch() async throws {
        let world = World()
        let a = world.phone("Ana")
        let controlled = Mutex<ControlledLedger?>(nil)
        let b = world.phone("Ben", calendar: FakeCalendarStore(status: .denied), ledger: { inner in
            let ledger = ControlledLedger(inner)
            controlled.withLock { $0 = ledger }
            return ledger
        })
        let ledger = controlled.withLock { $0! }
        try await world.start()
        try await a.findATime(with: [b])
        let (asked, _) = try await b.waitForQuestion()
        let conversation = await b.coordinator.interaction(asked)!.conversation

        await ledger.hold()
        try await b.service.answer(asked, with: .pass)
        try await eventually("retiring") { await ledger.retireCalls == 1 }
        // The app dies with the retirement still pending: it is never recorded.
        await b.service.flushCheckpoints()
        await b.service.shutdown()
        await ledger.abandonHeld()
        #expect(try await b.conversations.isRetired(conversation) == false)
        #expect(await b.coordinator.interaction(asked)?.state == .awaitingOwner)

        await b.restart()
        try await b.waitForState(asked, .ended(.declined))
        #expect(try await b.conversations.isRetired(conversation))
        await world.stop()
    }
}
