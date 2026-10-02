@testable import FindATime
import Foundation
import StarlingAvailability
import StarlingAvailabilityFakes
import StarlingCore
import StarlingFakes
import Testing

/// Device test 2 (issue #95): "dinner" became "tonight after 6 pm", and the
/// time could not be a range of dates. Find a time searches a range of days
/// with a daily window, and with no days named, the next 7 days in the
/// activity's usual hours.
@Suite(.serialized)
struct RangeTests {
    /// The days a set of slots falls on, as offsets from Monday.
    static func days(_ slots: [TimeSlot]) -> Set<Int> {
        Set(slots.map { Int($0.start.timeIntervalSince(T.monday) / 86_400) })
    }

    static func localHours(_ slots: [TimeSlot]) -> Set<Int> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = T.utc
        return Set(slots.map { calendar.component(.hour, from: $0.start) })
    }

    /// A range of dates the owner picks (Tuesday to Saturday), with evening
    /// hours: candidates spread over every day, only in the evening.
    @Test func aMultiDayRangeWithADailyWindow() async throws {
        let world = World()
        let a = world.phone("Ana", use: .justAskMe)
        let b = world.phone("Ben")
        try await world.start()

        let started = try await a.findATime(with: [b], range: [T.slot(24, 24 * 6)], daily: (17 * 60, 21 * 60))
        let (_, question) = try await a.waitForQuestion(started)
        // Five evenings of four hours is 20; at most 16 are offered, spread
        // from the first evening to the last.
        #expect(question.slots.count == 16)
        #expect(Self.days(question.slots) == [1, 2, 3, 4, 5])
        #expect(Self.localHours(question.slots).isSubset(of: [17, 18, 19, 20]))
        #expect(question.slots.first == T.slot(24 + 17, 24 + 18))
        #expect(question.slots.last == T.slot(24 * 5 + 20, 24 * 5 + 21))

        // The friend's agent takes the multi-day query and answers it.
        try await a.reply(started, question: question.revision, question.slots)
        let (_, proposal) = try await a.waitForProposal()
        #expect(proposal.plan?.time == question.slots.first)
        await world.stop()
    }

    /// With no days named, "dinner" means the next 7 days in the evening,
    /// never just tonight.
    @Test func dinnerWithNoDaysIsTheNextWeekOfEvenings() async throws {
        let world = World()
        let a = world.phone("Ana", use: .justAskMe)
        let b = world.phone("Ben")
        try await world.start()

        let started = try await a.findATime(with: [b], range: nil, activity: "dinner")
        let (_, question) = try await a.waitForQuestion(started)
        #expect(Self.localHours(question.slots).isSubset(of: Set(FindATimeDefaults.dinner.from / 60 ..< FindATimeDefaults.dinner.to / 60)))
        #expect(Self.days(question.slots) == Set(0...6))
        await world.stop()
    }

    /// The default the skill offers Compose: the next 7 days, with the
    /// activity's usual hours for meal words and none otherwise.
    @Test func theDefaultTimeComesFromTheSkill() throws {
        let now = T.at(13.25)
        let dinner = try FindATimeDefaults.timeConstraints(activity: Keyword("dinner"), now: now)
        let week = try TimeSlot(start: now, end: now.addingTimeInterval(7 * 86_400))
        #expect(dinner.contains { $0.rule == .within([week]) })
        #expect(dinner.contains { $0.rule == .dailyWindow(from: 17 * 60, to: 21 * 60) })

        let lunch = try FindATimeDefaults.timeConstraints(activity: Keyword("team lunch"), now: now)
        #expect(lunch.contains { $0.rule == .dailyWindow(from: 11 * 60, to: 14 * 60) })

        let stats = try FindATimeDefaults.timeConstraints(activity: Keyword("stats"), now: now)
        #expect(stats.count == 1)
        #expect(FindATimeDefaults.dailyWindow(for: nil) == nil)

        // The model is told to fill in only days the owner names.
        let hint = FindATimeSkill.descriptor.intent.slots.first { $0.issue == .time }!.hint
        #expect(hint.contains("leave it empty"))
    }
}
