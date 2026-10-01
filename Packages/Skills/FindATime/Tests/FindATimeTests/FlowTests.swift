@testable import FindATime
import Foundation
import StarlingAvailability
import StarlingAvailabilityFakes
import StarlingCore
import StarlingFakes
import Testing

/// Hourly slots from `from` to `to` on Monday.
func hours(_ from: Int, _ to: Int) -> [TimeSlot] { (from..<to).map { T.slot(Double($0), Double($0 + 1)) } }

@Suite(.serialized)
struct FlowTests {
    /// Brief 2.3: a calendar-driven agent schedules with an agent whose
    /// owner has no calendar. Mom's busy morning comes from her calendar;
    /// Priya's agent asks Priya one question.
    @Test func calendarAndNoCalendarAgentsAgreeOverLoopback() async throws {
        let world = World()
        let mom = world.phone("Mom", calendar: FakeCalendarStore(events: Canary.events()))
        let priya = world.phone("Priya", calendar: FakeCalendarStore(status: .denied))
        try await world.start()

        let started = try await mom.findATime(with: [priya])
        let (asked, question) = try await priya.waitForQuestion()
        #expect(question.asker == mom.id)
        #expect(question.revision == 1)
        // Mom is busy 9 to 12 and 13 to 14, so those hours are never offered.
        #expect(question.slots == [T.slot(12, 13)] + hours(14, 21))

        try await priya.reply(asked, question: 1, [T.slot(15, 16), T.slot(17, 18)])
        let (_, proposal) = try await mom.waitForProposal()
        #expect(proposal.plan?.time == T.slot(15, 16))
        #expect(proposal.plan?.activity == (try Keyword("stats")))
        let (priyaCard, priyaProposal) = try await priya.waitForProposal()
        #expect(priyaProposal.terms == proposal.terms)

        try await mom.accept(started)
        try await priya.accept(priyaCard)
        try await mom.waitForState(started, .planned)
        try await priya.waitForState(priyaCard, .planned)

        let momPlan = await mom.coordinator.interaction(started)?.plan
        let priyaPlan = await priya.coordinator.interaction(priyaCard)?.plan
        #expect(momPlan?.time == T.slot(15, 16))
        #expect(priyaPlan?.time == T.slot(15, 16))
        #expect(momPlan?.attendees == priyaPlan?.attendees)
        #expect(momPlan?.origin == priyaPlan?.origin)
        #expect(await mom.coordinator.interaction(started)?.timeSlot == T.slot(15, 16))
        #expect(await priya.coordinator.interaction(priyaCard)?.timeSlot == T.slot(15, 16))
        // Nobody's agent asked for a permission along the way.
        #expect(mom.calendar.requestCount == 0)
        #expect(priya.calendar.requestCount == 0)
        #expect(await mom.coordinator.rejected.isEmpty)
        #expect(await priya.coordinator.rejected.isEmpty)
        await world.stop()
    }

    /// The other direction: the starter has no calendar, so its owner picks
    /// times first; the friend's calendar answers without asking anyone.
    @Test func noCalendarStarterWithCalendarFriend() async throws {
        let world = World()
        let student = world.phone("Priya", calendar: FakeCalendarStore(), use: .justAskMe)
        let parent = world.phone("Mom", calendar: FakeCalendarStore(events: Canary.events()))
        try await world.start()

        let started = try await student.findATime(with: [parent])
        let (_, own) = try await student.waitForQuestion(started)
        #expect(own.asker == nil)
        #expect(own.slots == hours(9, 21))
        // "Just ask me" never reads the calendar, even with access.
        #expect(student.calendar.readCount == 0)

        try await student.reply(started, question: own.revision, [T.slot(10, 11), T.slot(16, 17)])
        let (_, proposal) = try await student.waitForProposal()
        // Mom is busy at 10, so 16:00 is the time.
        #expect(proposal.plan?.time == T.slot(16, 17))
        #expect(await parent.pendingQuestion() == nil)

        let (momCard, _) = try await parent.waitForProposal()
        try await student.accept(started)
        try await parent.accept(momCard)
        try await student.waitForState(started, .planned)
        try await parent.waitForState(momCard, .planned)
        await world.stop()
    }

    /// ADR 0013: Starling's sheet, then the system alert, then Don't Allow.
    /// The skill falls back to asking the owner and still completes.
    @Test func denialCompletesThroughAskOwner() async throws {
        let world = World()
        let calendar = FakeCalendarStore(status: .notDetermined, grantOnRequest: false)
        let owner = world.phone("Jo", calendar: calendar)
        let friend = world.phone("Sam", calendar: FakeCalendarStore(events: []))
        try await world.start()

        // The app's pre-permission sheet: one "Continue", then the alert.
        let access = CalendarAccess(store: calendar)
        #expect(access.shouldShowSheet)
        #expect(await access.request() == .denied)
        #expect(FindATimeCopy.deniedFallback == "No problem, your agent will ask you instead.")

        let started = try await owner.findATime(with: [friend])
        let (_, question) = try await owner.waitForQuestion(started)
        try await owner.reply(started, question: question.revision, [T.slot(18, 19)])
        let (friendCard, _) = try await friend.waitForProposal()
        try await owner.waitForState(started, .proposed)
        try await owner.accept(started)
        try await friend.accept(friendCard)
        try await owner.waitForState(started, .planned)
        try await friend.waitForState(friendCard, .planned)
        // Only the sheet's "Continue" asked; the skill never did.
        #expect(calendar.requestCount == 1)
        #expect(calendar.readCount == 0)
        await world.stop()
    }

    /// Rule 8: a friend's request never raises the system alert, even when
    /// the owner has not been asked yet. It asks the owner a question instead.
    @Test func aFriendsRequestNeverAsksForThePermission() async throws {
        let world = World()
        let asker = world.phone("Maya", calendar: FakeCalendarStore())
        let calendar = FakeCalendarStore(status: .notDetermined, grantOnRequest: true)
        let asked = world.phone("Jake", calendar: calendar)
        try await world.start()

        try await asker.findATime(with: [asked], chainedFrom: ConversationID())
        let (id, _) = try await asked.waitForQuestion()
        #expect(calendar.requestCount == 0)
        #expect(calendar.readCount == 0)
        let interaction = await asked.coordinator.interaction(id)
        #expect(interaction?.role == .invitee)
        #expect(interaction?.state == .awaitingOwner)
        await world.stop()
    }

    /// Three people, mixed calendars: the roster travels so everyone builds
    /// the same plan, and the time is one all three can make.
    @Test func groupOfThreeAgreesOnTheSameRoster() async throws {
        let world = World()
        let a = world.phone("Ana", calendar: FakeCalendarStore(events: Canary.events()))
        let b = world.phone("Ben", calendar: FakeCalendarStore(events: [FakeCalendarEvent(title: "Gym", start: T.at(12), end: T.at(16))]))
        let c = world.phone("Cy", calendar: FakeCalendarStore(status: .restricted))
        try await world.start()

        let started = try await a.findATime(with: [b, c])
        let (cAsked, question) = try await c.waitForQuestion()
        try await c.reply(cAsked, question: question.revision, [T.slot(14, 15), T.slot(16, 17), T.slot(19, 20)])
        let (_, proposal) = try await a.waitForProposal()
        // Ben is busy 12 to 16, so 16:00 is the first time all three can make.
        #expect(proposal.plan?.time == T.slot(16, 17))
        let roster = [a.id, b.id, c.id].sorted()
        #expect(proposal.terms[.people] == .peers(roster))

        let (bCard, bProposal) = try await b.waitForProposal()
        let (cCard, cProposal) = try await c.waitForProposal()
        #expect(bProposal.plan?.attendees.peers == roster)
        #expect(cProposal.plan?.attendees.peers == roster)
        try await b.accept(bCard)
        try await c.accept(cCard)
        try await a.accept(started)
        try await a.waitForState(started, .planned)
        try await b.waitForState(bCard, .planned)
        try await c.waitForState(cCard, .planned)
        await world.stop()
    }

    /// The time most friends can make wins; a friend who can make none of
    /// the offered times is told "no plan" and the others go ahead.
    @Test func mostFriendsWinsAndTheOddOneOutHearsNoPlan() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben", calendar: FakeCalendarStore(events: [FakeCalendarEvent(title: "Shift", start: T.at(8), end: T.at(24))]))
        let c = world.phone("Cy")
        try await world.start()

        let started = try await a.findATime(with: [b, c])
        let (_, proposal) = try await a.waitForProposal()
        #expect(proposal.plan?.attendees.peers == [a.id, c.id].sorted())
        // A pair needs no roster on the wire.
        #expect(proposal.terms[.people] == nil)
        try await b.waitForState(nil, .ended(.nobodyUp))
        #expect(await b.pendingQuestion() == nil)
        let (cCard, _) = try await c.waitForProposal()
        try await a.accept(started)
        try await c.accept(cCard)
        try await a.waitForState(started, .planned)
        try await c.waitForState(cCard, .planned)
        await world.stop()
    }

    @Test func nobodyFreeEndsQuietly() async throws {
        let world = World()
        let a = world.phone("Ana")
        let b = world.phone("Ben", calendar: FakeCalendarStore(events: [FakeCalendarEvent(title: "Trip", start: T.at(0), end: T.at(48))]))
        try await world.start()

        let started = try await a.findATime(with: [b])
        try await a.waitForState(started, .ended(.nobodyUp))
        try await b.waitForState(nil, .ended(.nobodyUp))
        // Nobody was asked anything and no card went up.
        #expect(await a.coordinator.all().allSatisfy { $0.proposal == nil })
        #expect(await b.coordinator.all().allSatisfy { $0.proposal == nil && $0.history.allSatisfy { $0.state != .awaitingOwner } })
        await world.stop()
    }
}
