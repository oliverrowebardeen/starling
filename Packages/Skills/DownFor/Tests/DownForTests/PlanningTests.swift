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
        // A subset of the starter's own candidates: a yes or no on each.
        #expect(profile.acceptableActivities(candidates: candidates, matches: matches) == ["boba run", "movie"].map(T.keyword))
    }
}

@Suite struct GroupPlannerTests {
    let hub = PeerID.random()
    let peers = (0..<3).map { _ in PeerID.random() }.sorted()

    func answers(_ slots: [TimeSlot], _ activities: [String]) -> CandidateAnswers {
        CandidateAnswers(overlap: slots, activities: activities.map(T.keyword))
    }

    func halfHours(_ from: Double, _ to: Double) -> [TimeSlot] {
        stride(from: from, to: to, by: 0.5).map { T.slot($0, $0 + 0.5) }
    }

    @Test func picksThePlanThatIncludesTheMostFriends() throws {
        let (terms, members) = try #require(GroupPlanner.plan(
            hub: hub, liked: ["boba", "tacos"].map(T.keyword),
            candidates: [
                peers[0]: answers(halfHours(19, 21), ["boba"]),
                peers[1]: answers(halfHours(20, 22), ["boba", "tacos"]),
                peers[2]: answers(halfHours(19, 20), ["tacos"]),
            ],
            maxMinutes: 120, now: T.now
        ))
        // Boba at 20:00 has two friends; nothing has all three.
        #expect(members == [peers[0], peers[1]])
        #expect(terms[.people] == .peers([hub, peers[0], peers[1]]))
        #expect(terms[.activity] == .keywords([T.keyword("boba")]))
        #expect(terms[.time] == .slots([T.slot(20, 21)]))
        // Budget never leaves the phone (ADR 0019).
        #expect(terms[.budget] == nil)
    }

    @Test func friendsWhoDidNotAskEachOtherAreNeverGrouped() throws {
        // All three share boba at 19:00, but peers[1] and peers[2] did not
        // include each other: the plan is the starter and one of them.
        let everyone = answers(halfHours(19, 21), ["boba"])
        let (terms, members) = try #require(GroupPlanner.plan(
            hub: hub, liked: [T.keyword("boba")], candidates: [peers[1]: everyone, peers[2]: everyone],
            maxMinutes: 120, now: T.now, together: { _, _ in false }
        ))
        #expect(members == [peers[1]])
        #expect(terms[.people] == nil)
        // Asking in one direction only is not enough either.
        #expect(GroupPlanner.largestGroup(of: [peers[0], peers[1], peers[2]], together: { asker, _ in asker == peers[0] }) == [peers[0]])
        #expect(GroupPlanner.largestGroup(of: [peers[0], peers[1], peers[2]], together: { $0 != peers[2] && $1 != peers[2] }) == [peers[0], peers[1]])
    }

    @Test func tiesGoToTheStartersFirstChoiceThenTheEarliestTime() throws {
        let (terms, members) = try #require(GroupPlanner.plan(
            hub: hub, liked: ["boba", "tacos"].map(T.keyword),
            candidates: [peers[0]: answers(halfHours(19, 23), ["tacos", "boba"])],
            maxMinutes: 120, now: T.now
        ))
        #expect(terms[.activity] == .keywords([T.keyword("boba")]))
        #expect(terms[.time] == .slots([T.slot(19, 21)]))
        // A pair: no roster on the wire.
        #expect(members == [peers[0]] && terms[.people] == nil)
    }

    @Test func aPlanThatMustIncludeAFriendDoes() throws {
        // Two friends share boba at 19:00; a third shares only tacos. The
        // largest plan leaves the third out; one that must include it is
        // tacos with the starter alone.
        let candidates = [
            peers[0]: answers(halfHours(19, 21), ["boba"]),
            peers[1]: answers(halfHours(19, 21), ["boba"]),
            peers[2]: answers(halfHours(19, 21), ["tacos"]),
        ]
        let liked = ["boba", "tacos"].map(T.keyword)
        #expect(GroupPlanner.plan(hub: hub, liked: liked, candidates: candidates, maxMinutes: 120, now: T.now)?.members == [peers[0], peers[1]])
        let (terms, members) = try #require(GroupPlanner.plan(hub: hub, liked: liked, candidates: candidates, maxMinutes: 120, now: T.now, including: peers[2]))
        #expect(members == [peers[2]])
        #expect(terms[.activity] == .keywords([T.keyword("tacos")]))
        // Friends who did not ask it are not added to it.
        let alone = GroupPlanner.plan(
            hub: hub, liked: liked, candidates: candidates, maxMinutes: 120, now: T.now, including: peers[0], together: { _, _ in false }
        )
        #expect(alone?.members == [peers[0]])
    }

    @Test func noSharedActivityMeansNoPlan() {
        #expect(GroupPlanner.plan(
            hub: hub, liked: [T.keyword("boba")],
            candidates: [peers[0]: answers(halfHours(19, 21), [])], maxMinutes: 120, now: T.now
        ) == nil)
    }

    @Test func slotsThatHaveStartedAreSkipped() throws {
        let (terms, _) = try #require(GroupPlanner.plan(
            hub: hub, liked: [T.keyword("boba")],
            candidates: [peers[0]: answers(halfHours(19, 21), ["boba"])], maxMinutes: 120, now: T.at(19.6)
        ))
        #expect(terms[.time] == .slots([T.slot(20, 21)]))
    }
}
