import Foundation
@testable import DownFor
import StarlingCore
import StarlingFakes
import StarlingNegotiation
import Testing

@Suite struct ProfileTests {
    let me = PeerID.random()
    let hub = PeerID.random()

    func profile(liked: [String] = ["boba"], avoided: [String] = [], budget: Int64? = 15) throws -> DownForProfile {
        DownForProfile(rules: try T.rules(time: [T.slot(19, 22)], liked: liked, avoided: avoided, maxBudget: budget), inputs: [], expiresAt: T.at(24), timeZone: T.utc)
    }

    func plan(time: TimeSlot = T.slot(20, 21), activity: [String] = ["boba"], budget: Int64? = nil, roster: [PeerID]? = nil, extra: [IssueKey: IssueValue] = [:]) throws -> Terms {
        var values: [IssueKey: IssueValue] = [.time: .slots([time]), .activity: .keywords(activity.map(T.keyword))]
        if let roster { values[.people] = .peers(roster) }
        if let budget { values[.budget] = .amount(T.usd(budget)) }
        for (key, value) in extra { values[key] = value }
        return try Terms(values)
    }

    @Test func permitsAPlanInsideEveryLimit() throws {
        let profile = try profile()
        // A pair: the roster is the two ends, from either side.
        #expect(profile.permits(try plan(budget: 12), me: me, hub: hub, member: me, now: T.now))
        #expect(profile.permits(try plan(budget: 12), me: hub, hub: hub, member: me, now: T.now))
        // A group carries its roster, starter first.
        let other = PeerID.random()
        #expect(profile.permits(try plan(roster: [hub, me, other]), me: me, hub: hub, member: me, now: T.now))
    }

    @Test func refusesPlansOutsideTheLimitsOrTheShape() throws {
        let profile = try profile(avoided: ["sushi"])
        let refused: [Terms] = [
            try plan(time: T.slot(22, 23)),                                   // outside available time
            try plan(budget: 20),                                             // over budget
            try plan(activity: ["sushi"]),                                    // avoided
            try plan(roster: [me, hub, PeerID.random()]),                     // starter not first
            try plan(roster: [hub, PeerID.random(), PeerID.random()]),        // we are not in it
            try plan(roster: [hub, me]),                                      // a pair never sends its roster
            try plan(extra: [.place: .keywords([T.keyword("nearby")])]),      // not a Down for... issue
            try Terms([.time: .slots([T.slot(20, 21)]), .people: .peers([hub, me])]), // no activity
        ]
        for terms in refused { #expect(!profile.permits(terms, me: me, hub: hub, member: me, now: T.now), "\(terms)") }
        // A plan that has started is refused too.
        #expect(!profile.permits(try plan(), me: me, hub: hub, member: me, now: T.at(20.1)))
    }

    @Test func aChainedTimeSlotNarrowsTheRequest() throws {
        let narrowed = DownForProfile(
            rules: try T.rules(time: [T.slot(19, 23)], liked: ["boba"]), inputs: [.timeSlot(T.slot(21, 22))], expiresAt: T.at(24), timeZone: T.utc
        )
        #expect(narrowed.tokens(now: T.now).slots == [T.slot(21, 21.5), T.slot(21.5, 22)])
    }

    @Test func answersKeepOnlyWhatCodeAllows() throws {
        let profile = try profile(liked: ["food"], avoided: ["sushi"])
        let candidates = ["boba run", "sushi", "movie"].map(T.keyword)
        // The model claims every pair, the avoided one included.
        let matches = candidates.map { KeywordMatch(wanted: T.keyword("food"), offered: $0, strength: .satisfies) }
            + [KeywordMatch(wanted: T.keyword("invented"), offered: T.keyword("movie"), strength: .equivalent)]
        #expect(profile.acceptableActivities(candidates: candidates, matches: matches) == ["boba run", "movie"].map(T.keyword))
        #expect(profile.budgetAnswer(for: T.usd(30)) == T.usd(15))
        #expect(profile.budgetAnswer(for: try MoneyAmount(minorUnits: 100, currency: "EUR")) == nil)
    }
}

@Suite struct GroupPlannerTests {
    let hub = PeerID.random()
    let peers = (0..<3).map { _ in PeerID.random() }.sorted()

    func answers(_ slots: [TimeSlot], _ activities: [String], budget: Int64? = nil) -> CandidateAnswers {
        CandidateAnswers(overlap: slots, activities: activities.map(T.keyword), budget: budget.map(T.usd))
    }

    func halfHours(_ from: Double, _ to: Double) -> [TimeSlot] {
        stride(from: from, to: to, by: 0.5).map { T.slot($0, $0 + 0.5) }
    }

    @Test func picksThePlanThatIncludesTheMostFriends() throws {
        let (terms, members) = try #require(GroupPlanner.plan(
            hub: hub, liked: ["boba", "tacos"].map(T.keyword), budgetCap: T.usd(20),
            candidates: [
                peers[0]: answers(halfHours(19, 21), ["boba"], budget: 15),
                peers[1]: answers(halfHours(20, 22), ["boba", "tacos"], budget: 12),
                peers[2]: answers(halfHours(19, 20), ["tacos"]),
            ],
            maxMinutes: 120, now: T.now
        ))
        // Boba at 20:00 has two friends; nothing has all three.
        #expect(members == [peers[0], peers[1]])
        #expect(terms[.people] == .peers([hub, peers[0], peers[1]]))
        #expect(terms[.activity] == .keywords([T.keyword("boba")]))
        #expect(terms[.time] == .slots([T.slot(20, 21)]))
        #expect(terms[.budget] == .amount(T.usd(12)))
    }

    @Test func tiesGoToTheStartersFirstChoiceThenTheEarliestTime() throws {
        let (terms, members) = try #require(GroupPlanner.plan(
            hub: hub, liked: ["boba", "tacos"].map(T.keyword), budgetCap: nil,
            candidates: [peers[0]: answers(halfHours(19, 23), ["tacos", "boba"])],
            maxMinutes: 120, now: T.now
        ))
        #expect(terms[.activity] == .keywords([T.keyword("boba")]))
        #expect(terms[.time] == .slots([T.slot(19, 21)]))
        #expect(terms[.budget] == nil)
        // A pair: no roster on the wire.
        #expect(members == [peers[0]] && terms[.people] == nil)
    }

    @Test func noSharedActivityMeansNoPlan() {
        #expect(GroupPlanner.plan(
            hub: hub, liked: [T.keyword("boba")], budgetCap: nil,
            candidates: [peers[0]: answers(halfHours(19, 21), [])], maxMinutes: 120, now: T.now
        ) == nil)
    }

    @Test func slotsThatHaveStartedAreSkipped() throws {
        let (terms, _) = try #require(GroupPlanner.plan(
            hub: hub, liked: [T.keyword("boba")], budgetCap: nil,
            candidates: [peers[0]: answers(halfHours(19, 21), ["boba"])], maxMinutes: 120, now: T.at(19.6)
        ))
        #expect(terms[.time] == .slots([T.slot(20, 21)]))
    }
}
