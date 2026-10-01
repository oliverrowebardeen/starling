import Foundation
import StarlingAvailability
import StarlingCore
import Testing

struct FreeTimeTests {
    @Test func busyBlocksCarveTheWindow() {
        let blocks = [
            BusyBlock(start: T.at(10), end: T.at(11), isAllDay: false, availability: .busy),
            BusyBlock(start: T.at(10.5), end: T.at(12), isAllDay: false, availability: .tentative),
            BusyBlock(start: T.at(15), end: T.at(16), isAllDay: false, availability: .unavailable),
        ]
        let free = FreeTime.free(in: T.slot(9, 18), around: blocks)
        #expect(free == [T.slot(9, 10), T.slot(12, 15), T.slot(16, 18)])
    }

    @Test func freeEventsAndOpenAllDayEventsLeaveTimeFree() {
        let blocks = [
            BusyBlock(start: T.at(10), end: T.at(11), isAllDay: false, availability: .free),
            // A birthday or holiday: all day, not marked busy.
            BusyBlock(start: T.at(0), end: T.at(24), isAllDay: true, availability: .notSupported),
            BusyBlock(start: T.at(0), end: T.at(24), isAllDay: true, availability: .free),
        ]
        #expect(FreeTime.free(in: T.slot(9, 18), around: blocks) == [T.slot(9, 18)])
    }

    @Test func busyAllDayEventsAndUnsupportedTimedEventsBlock() {
        let allDay = BusyBlock(start: T.at(0), end: T.at(24), isAllDay: true, availability: .busy)
        #expect(FreeTime.free(in: T.slot(9, 18), around: [allDay]).isEmpty)
        let timed = BusyBlock(start: T.at(9), end: T.at(17), isAllDay: false, availability: .notSupported)
        #expect(FreeTime.free(in: T.slot(9, 18), around: [timed]) == [T.slot(17, 18)])
    }

    @Test func busyTimeWidensToWholeMinutes() {
        // 10:00:30 to 10:59:30 still takes 10:00 to 11:00.
        let block = BusyBlock(start: T.at(10).addingTimeInterval(30), end: T.at(11).addingTimeInterval(-30), isAllDay: false, availability: .busy)
        #expect(FreeTime.free(in: T.slot(9, 12), around: [block]) == [T.slot(9, 10), T.slot(11, 12)])
    }

    @Test func shortGapsAreDropped() {
        let blocks = [
            BusyBlock(start: T.at(9), end: T.at(10), isAllDay: false, availability: .busy),
            BusyBlock(start: T.at(10.25), end: T.at(12), isAllDay: false, availability: .busy),
        ]
        #expect(FreeTime.free(in: T.slot(9, 13), around: blocks, minimumMinutes: 30) == [T.slot(12, 13)])
    }

    @Test func malformedBlocksAreEmpty() {
        let backwards = BusyBlock(start: T.at(11), end: T.at(10), isAllDay: false, availability: .busy)
        #expect(!backwards.blocksTime)
        #expect(FreeTime.free(in: T.slot(9, 12), around: [backwards]) == [T.slot(9, 12)])
    }

    @Test func acceptableKeepsWholeCandidatesOnly() {
        let candidates = [T.slot(9, 10), T.slot(10, 11), T.slot(12, 13), T.slot(12, 13)]
        let free = [T.slot(9, 10.5), T.slot(12, 14)]
        #expect(FreeTime.acceptable(candidates, within: free) == [T.slot(9, 10), T.slot(12, 13)])
    }

    /// A tripwire: a `BusyBlock` is the only thing that leaves a calendar
    /// store, so it must never grow a field that could hold event details.
    @Test func busyBlockHoldsNoEventDetails() {
        let block = BusyBlock(start: T.at(9), end: T.at(10), isAllDay: false, availability: .busy)
        let fields = Set(Mirror(reflecting: block).children.compactMap(\.label))
        #expect(fields == ["start", "end", "isAllDay", "availability"])
    }
}

struct CandidateGridTests {
    @Test func slotsStartOnTheGridInsideTheDailyWindow() throws {
        let grid = try CandidateGrid(durationMinutes: 60, dailyFrom: 9 * 60, dailyTo: 12 * 60)
        let slots = grid.slots(in: [T.slot(0, 48)], notBefore: T.at(0), timeZone: T.utc)
        #expect(slots == [T.slot(9, 10), T.slot(10, 11), T.slot(11, 12), T.slot(33, 34), T.slot(34, 35), T.slot(35, 36)])
    }

    @Test func slotsRespectTheRangeAndNow() throws {
        let grid = try CandidateGrid(durationMinutes: 60, dailyFrom: 9 * 60, dailyTo: 18 * 60)
        // Range from 10:30; now is 13:10, so the first slot starts at 14:00.
        let slots = grid.slots(in: [T.slot(10.5, 16.5)], notBefore: T.at(13) + 600, timeZone: T.utc)
        #expect(slots == [T.slot(14, 15), T.slot(15, 16)])
    }

    @Test func slotsFollowTheOwnersTimeZone() throws {
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let grid = try CandidateGrid(durationMinutes: 60, dailyFrom: 9 * 60, dailyTo: 10 * 60)
        // 9:00 in Los Angeles on Monday 5 October 2026 (PDT, UTC-7) is 16:00 UTC.
        let slots = grid.slots(in: [T.slot(0, 24)], notBefore: T.at(0), timeZone: losAngeles)
        #expect(slots == [T.slot(16, 17)])
    }

    @Test func overlappingRangesDoNotDuplicate() throws {
        let grid = try CandidateGrid(durationMinutes: 60, dailyFrom: 9 * 60, dailyTo: 11 * 60)
        let slots = grid.slots(in: [T.slot(0, 24), T.slot(9, 11)], notBefore: T.at(0), timeZone: T.utc)
        #expect(slots == [T.slot(9, 10), T.slot(10, 11)])
    }

    @Test func thinningSpreadsAcrossTheWholeRange() {
        let slots = (0..<84).map { T.slot(Double($0), Double($0) + 1) }
        let thinned = CandidateGrid.thinned(slots, to: 4)
        #expect(thinned == [slots[0], slots[27], slots[55], slots[83]])
        #expect(CandidateGrid.thinned(Array(slots.prefix(3)), to: 4) == Array(slots.prefix(3)))
        #expect(CandidateGrid.thinned(slots, to: 0).isEmpty)
    }

    @Test func invalidGridsThrow() {
        #expect(throws: ValidationError.self) { try CandidateGrid(durationMinutes: 2) }
        #expect(throws: ValidationError.self) { try CandidateGrid(durationMinutes: 60, dailyFrom: 600, dailyTo: 630) }
        #expect(throws: ValidationError.self) { try CandidateGrid(durationMinutes: 60, dailyFrom: -1) }
    }
}
