@testable import StarlingAgent
import Foundation
import StarlingCore
import StarlingFakes
import Testing

/// Oliver's two-phone run (issue #95, 2026-10-02).
@Suite struct DeviceTestTwoTests {
    let utc = TimeZone(identifier: "UTC")!
    /// 2026-10-02 13:15 UTC, as in the run.
    var quarterPastOne: Date { Date(timeIntervalSince1970: 1_790_947_800 + 15 * 60) }

    func at(_ hour: Double, days: Int = 0) -> Date {
        Date(timeIntervalSince1970: 1_790_899_200 + Double(days) * 86_400 + hour * 3600)
    }

    func time(_ wants: [String], said utterance: String, now: Date) throws -> [Constraint] {
        try SkillOutputMapping.parsed(
            RawIntent(rules: RawRules(wants: wants)), utterance: utterance, skill: SampleSkills.downFor, now: now, timeZone: utc
        ).constraints[.time]
    }

    // MARK: No time given

    @Test func aMealWithNoTimeIsItsUsualWindow() throws {
        // "dinner" at 1:15 PM is this evening, not 1:30 PM.
        #expect(try time(["dinner"], said: "dinner", now: quarterPastOne) == [try Constraint(.within([try TimeSlot(start: at(18), end: at(21))]))])
        // Lunch at 11 AM leaves an hour's notice, on the half hour.
        #expect(try time(["lunch"], said: "lunch", now: at(11)) == [try Constraint(.within([try TimeSlot(start: at(12), end: at(14))]))])
        // Breakfast at 2 PM is tomorrow's.
        #expect(try time(["breakfast"], said: "breakfast", now: quarterPastOne) == [try Constraint(.within([try TimeSlot(start: at(8, days: 1), end: at(11, days: 1))]))])
        // Dinner at 8:30 PM is too late for tonight.
        #expect(try time(["dinner"], said: "dinner", now: at(20.5)) == [try Constraint(.within([try TimeSlot(start: at(18, days: 1), end: at(21, days: 1))]))])
    }

    @Test func noMealAndNoTimeLeavesTheTimeOpen() throws {
        #expect(try time(["boba"], said: "boba", now: quarterPastOne).isEmpty)
    }

    @Test func aStatedTimeWins() throws {
        // "dinner at 5": the owner's 5 PM, not the usual dinner window.
        #expect(try SkillOutputMapping.parsed(
            RawIntent(rules: RawRules(earliestHour: 17, wants: ["dinner"])), utterance: "dinner at 5", skill: SampleSkills.downFor,
            now: quarterPastOne, timeZone: utc
        ).constraints[.time] == [try Constraint(.dailyWindow(from: 17 * 60, to: 24 * 60))])
    }

    // MARK: The sentence

    @Test func theSentenceIsInSentenceCase() throws {
        let facts = ProposalFacts(skill: SampleSkills.downFor.ref, friendNames: ["Riley"], activity: try Keyword("dinner"), time: nil, place: nil, timeZone: utc)
        #expect(try SkillOutputMapping.sentence("YOU and Riley are both down for dinner.", facts: facts, time: nil) == "You and Riley are both down for dinner.")
        // A friend's name keeps the owner's spelling, capitals included.
        let jj = ProposalFacts(skill: SampleSkills.downFor.ref, friendNames: ["JJ"], activity: try Keyword("dinner"), time: nil, place: nil, timeZone: utc)
        #expect(try SkillOutputMapping.sentence("you and JJ are both down for dinner.", facts: jj, time: nil) == "You and JJ are both down for dinner.")
        // A time that starts a sentence starts with a capital.
        let timed = ProposalFacts(skill: SampleSkills.downFor.ref, friendNames: ["Riley"], activity: try Keyword("dinner"), time: try TimeSlot(start: at(18), end: at(20)), place: nil, timeZone: utc)
        #expect(try SkillOutputMapping.sentence("You and Riley are both down for dinner. {time}?", facts: timed, time: "tonight at 6 PM") == "You and Riley are both down for dinner. Tonight at 6 PM?")
    }

    // MARK: Reading the same draft again

    @Test func theSameWordsAreReadOnce() {
        let cache = SkillReadCache()
        let key = SkillReadCache.intentKey("dinner  tonight ", skill: SampleSkills.downFor)
        #expect(key == SkillReadCache.intentKey("dinner tonight", skill: SampleSkills.downFor))
        #expect(key != SkillReadCache.intentKey("dinner tonight", skill: SampleSkills.findATime))
        #expect(cache.intent(for: key) == nil)
        let raw = RawIntent(rules: RawRules(wants: ["dinner"]))
        cache.remember(intent: raw, for: key)
        #expect(cache.intent(for: key) == raw)
        // "No skill" is an answer worth keeping too.
        let route = SkillReadCache.routeKey("thanks!", skills: [SampleSkills.downFor])
        cache.remember(route: nil, for: route)
        #expect(cache.route(for: route) == .some(nil))
        // Old drafts give way to new ones.
        for index in 0..<SkillReadCache.capacity { cache.remember(intent: raw, for: "draft \(index)") }
        #expect(cache.intent(for: key) == nil)
    }
}
