@testable import FindATime
import Foundation
import StarlingAvailability
import StarlingAvailabilityFakes
import StarlingCore
import StarlingFakes
import Testing

/// Revisions, deadlines, retries, and endings.
@Suite(.serialized)
struct LifecycleTests {
    /// A pass in a group: the others get a new proposal (revision 2) for
    /// the same time, and an "I'm in" on the old card never accepts it.
    @Test func aPassInAGroupGivesANewRevisionAndOldCardsAreStale() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben")
        let c = world.phone("Cy")
        try await world.start()

        let started = try await a.findATime(with: [b, c])
        _ = try await a.waitForProposal(revision: 1)
        let (bCard, _) = try await b.waitForProposal(revision: 1)
        let (cCard, _) = try await c.waitForProposal(revision: 1)
        try await a.accept(started, revision: 1)
        try await c.service.answer(cCard, with: .pass)

        let (_, second) = try await a.waitForProposal(revision: 2)
        #expect(second.plan?.attendees.peers == [a.id, b.id].sorted())
        #expect(second.terms[.people] == nil)
        await #expect(throws: FindATimeError.staleProposal(current: 2)) { try await a.accept(started, revision: 1) }
        let (bSecond, bProposal) = try await b.waitForProposal(revision: 2)
        #expect(bSecond == bCard)
        #expect(bProposal.terms == second.terms)
        await #expect(throws: FindATimeError.staleProposal(current: 2)) { try await b.accept(bCard, revision: 1) }

        try await a.accept(started, revision: 2)
        try await b.accept(bCard, revision: 2)
        try await a.waitForState(started, .planned)
        try await b.waitForState(bCard, .planned)
        try await c.waitForState(cCard, .ended(.declined))
        #expect(await a.coordinator.interaction(started)?.plan?.attendees.peers == [a.id, b.id].sorted())
        #expect(await a.coordinator.rejected.isEmpty)
        #expect(await b.coordinator.rejected.isEmpty)
        await world.stop()
    }

    @Test func repliesBindToTheQuestionAndItsTimes() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben", calendar: FakeCalendarStore(status: .denied))
        try await world.start()

        try await a.findATime(with: [b])
        let (asked, question) = try await b.waitForQuestion()
        await #expect(throws: FindATimeError.staleQuestion(current: 1)) { try await b.reply(asked, question: 2, [question.slots[0]]) }
        await #expect(throws: FindATimeError.invalidReply) { try await b.reply(asked, question: 1, [T.slot(3, 4)]) }
        await #expect(throws: FindATimeError.invalidReply) {
            try await b.service.answer(asked, with: .reply(question: 1, .keywords([Keyword("anything")])))
        }
        await #expect(throws: FindATimeError.staleProposal(current: nil)) { try await b.accept(asked) }
        try await b.reply(asked, question: 1, [question.slots[2]])
        await #expect(throws: FindATimeError.staleQuestion(current: nil)) { try await b.reply(asked, question: 1, [question.slots[2]]) }
        _ = try await b.waitForProposal()
        await #expect(throws: FindATimeError.unknownInteraction) { try await b.accept(InteractionID()) }
        await world.stop()
    }

    @Test func anEmptyReplyIsNoTimeAndThePassLooksTheSame() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben", calendar: FakeCalendarStore(status: .denied))
        let c = world.phone("Cy", calendar: FakeCalendarStore(status: .denied))
        try await world.start()

        let started = try await a.findATime(with: [b, c])
        let (bAsked, bQuestion) = try await b.waitForQuestion()
        let (cAsked, _) = try await c.waitForQuestion()
        try await b.reply(bAsked, question: bQuestion.revision, [])
        try await c.service.answer(cAsked, with: .pass)
        try await a.waitForState(started, .ended(.nobodyUp))
        try await b.waitForState(bAsked, .ended(.nobodyUp))
        try await c.waitForState(cAsked, .ended(.declined))
        // On the wire, "none of these" and a pass are the same message.
        let replies = world.envelopes.filter { $0.recipient == a.id && $0.skill != nil }
        #expect(replies.count == 2)
        for reply in replies {
            guard case .reject(let rejection) = reply.body else { Issue.record("expected a rejection"); continue }
            #expect(rejection.reason == .noOverlap)
        }
        await world.stop()
    }

    @Test func theStarterPassingTellsEveryoneNoPlan() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben")
        try await world.start()

        let started = try await a.findATime(with: [b])
        _ = try await a.waitForProposal()
        let (bCard, _) = try await b.waitForProposal()
        try await b.accept(bCard)
        try await a.service.answer(started, with: .pass)
        try await a.waitForState(started, .ended(.declined))
        try await b.waitForState(bCard, .ended(.nobodyUp))
        await world.stop()
    }

    @Test func withdrawingClearsTheFriendsQuestion() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben", calendar: FakeCalendarStore(status: .denied))
        try await world.start()

        let started = try await a.findATime(with: [b])
        let (asked, _) = try await b.waitForQuestion()
        await a.service.withdraw(started)
        try await a.waitForState(started, .ended(.withdrawn))
        // The question no longer matters: it leaves Needs you as expired.
        try await b.waitForState(asked, .ended(.expired))
        await world.stop()
    }

    /// A request that ends before any query left tells nobody anything.
    @Test func friendsNeverAskedHearNothing() async throws {
        let world = World()
        let a = world.phone("Ana", use: .justAskMe)
        let b = world.phone("Ben")
        try await world.start()

        let expiring = try await a.findATime(with: [b], expiresIn: 1)
        _ = try await a.waitForQuestion(expiring)
        world.clock.advance(hours: 2)
        try await a.waitForState(expiring, .ended(.expired))

        let withdrawn = try await a.findATime(with: [b])
        _ = try await a.waitForQuestion(withdrawn)
        await a.service.withdraw(withdrawn)
        try await a.waitForState(withdrawn, .ended(.withdrawn))
        try await Task.sleep(for: .milliseconds(60))
        #expect(world.envelopes.allSatisfy { $0.skill == nil })
        await world.stop()
    }

    @Test func noFriendsIsUnsupported() async throws {
        let world = World()
        let a = world.phone("Ana")
        try await world.start()
        let started = try await a.findATime(with: [])
        try await a.waitForState(started, .ended(.unsupported))
        await world.stop()
    }

    @Test func anEmptyRangeIsRefusedBeforeAnythingHappens() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben")
        try await world.start()
        // 22:00 to 23:00 is outside the 9 to 9 default window.
        await #expect(throws: FindATimeError.noTimesInRange) { try await a.findATime(with: [b], range: [T.slot(22, 23)]) }
        // A daily window shorter than one slot.
        await #expect(throws: FindATimeError.noTimesInRange) { try await a.findATime(with: [b], daily: (600, 630)) }
        #expect(world.envelopes.allSatisfy { $0.skill == nil })
        await world.stop()
    }

    @Test func theOwnersDailyWindowNarrowsTheOffer() async throws {
        let world = World()
        let a = world.phone("Ana", use: .justAskMe)
        let b = world.phone("Ben")
        try await world.start()
        let started = try await a.findATime(with: [b], daily: (18 * 60, 21 * 60))
        let (_, question) = try await a.waitForQuestion(started)
        #expect(question.slots == hours(18, 21))
        await world.stop()
    }

    // MARK: Deadlines

    @Test func theRequestExpiresAndTheFriendsQuestionGoesWithIt() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben", calendar: FakeCalendarStore(status: .denied))
        try await world.start()

        let started = try await a.findATime(with: [b], expiresIn: 1)
        let (asked, _) = try await b.waitForQuestion()
        world.clock.advance(hours: 2)
        try await a.waitForState(started, .ended(.expired))
        try await b.waitForState(asked, .ended(.expired))
        await world.stop()
    }

    @Test func silentFriendsAreLeftOutAfterTheAnswerWait() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben")
        let c = world.phone("Cy", calendar: FakeCalendarStore(status: .denied))
        try await world.start()

        let started = try await a.findATime(with: [b, c])
        let (cAsked, _) = try await c.waitForQuestion()
        // Cy never answers. After the answer wait, Ana goes ahead with Ben.
        world.clock.advance(hours: 1)
        let (_, proposal) = try await a.waitForProposal()
        #expect(proposal.plan?.attendees.peers == [a.id, b.id].sorted())
        try await c.waitForState(cAsked, .ended(.expired))
        _ = started
        await world.stop()
    }

    @Test func theInviteeGivesUpAfterItsLifetime() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben", calendar: FakeCalendarStore(status: .denied))
        try await world.start()

        let started = try await a.findATime(with: [b, b], expiresIn: 24)
        let (asked, _) = try await b.waitForQuestion()
        world.clock.advance(hours: 7)
        try await b.waitForState(asked, .ended(.expired))
        // Ana hears "no plan" from Ben and ends.
        try await a.waitForState(started, .ended(.nobodyUp))
        await world.stop()
    }

    @Test func aPlanIsDoneWhenItsTimePasses() async throws {
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
        try await b.waitForState(bCard, .planned)
        world.clock.advance(hours: 30)
        try await a.waitForState(started, .done)
        try await b.waitForState(bCard, .done)
        await world.stop()
    }

    // MARK: Lost messages

    @Test func lostAnswerProposalAndConfirmationAreRecovered() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben")
        try await world.start()
        await b.transport.lose(2) { $0.body.kind == .answer }
        await a.transport.lose(1) { $0.body.kind == .propose }
        await a.transport.lose(2) { $0.body.kind == .accept }

        let started = try await a.findATime(with: [b])
        _ = try await a.waitForProposal()
        let (bCard, _) = try await b.waitForProposal()
        try await a.accept(started)
        try await b.accept(bCard)
        try await a.waitForState(started, .planned)
        try await b.waitForState(bCard, .planned)
        #expect(await a.transport.lost.count == 3)
        #expect(await b.transport.lost.count == 2)
        // One plan on each side, however many retries crossed.
        #expect(await a.coordinator.produced.values.flatMap { $0 }.count == 2)
        #expect(await b.coordinator.produced.values.flatMap { $0 }.count == 2)
        await world.stop()
    }

    @Test func aLinkThatComesBackGetsWhatItMissed() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben")
        try await world.start()
        await world.hub.partition(a.id, b.id)

        let started = try await a.findATime(with: [b])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await b.coordinator.all().isEmpty)
        await world.hub.heal(a.id, b.id)
        _ = try await a.waitForProposal()
        _ = started
        await world.stop()
    }
}
