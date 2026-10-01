import Foundation
import StarlingCore
@testable import StarlingNegotiation
import Testing

@Suite struct DownProfileTests {
    func profile(
        time: [TimeSlot] = [T.slot(19, 23)],
        liked: [String] = [],
        avoided: [String] = [],
        maxBudget: Int64? = nil,
        level: DownLevel = .down
    ) throws -> DownProfile {
        let rules = OwnerRules(constraints: try T.constraints(time: time, liked: liked, avoided: avoided, maxBudget: maxBudget))
        return DownProfile(intent: DownIntent(rules: rules, level: level, expiresAt: Timestamp(T.at(24))), now: T.now, timeZone: TimeZone(identifier: "UTC")!)
    }

    // MARK: Gate

    @Test func compliantPlansPass() throws {
        let me = try profile(avoided: ["sushi"], maxBudget: 15)
        #expect(me.permits(try T.plan(time: T.slot(19, 21), activity: ["tacos"], budget: 15)))
        #expect(me.permits(try T.plan(time: T.slot(19, 21))))
    }

    @Test func plansThatBreakAHardLimitFail() throws {
        let me = try profile(avoided: ["sushi"], maxBudget: 15)
        #expect(!me.permits(try T.plan(time: T.slot(19, 21), budget: 16)))
        #expect(!me.permits(try T.plan(time: T.slot(19, 21), activity: ["tacos", "sushi"])))
        #expect(!me.permits(try T.plan(time: T.slot(22, 24))))
        #expect(!me.permits(try T.plan(time: T.slot(18, 19))))
        #expect(me.violations(of: try Terms([.time: .slots([T.slot(19, 20)]), .budget: .amount(try MoneyAmount(minorUnits: 100, currency: "EUR"))]))
            == [LimitViolation(issue: .budget, reason: .currencyMismatch)])
    }

    @Test func malformedPlansFail() throws {
        let me = try profile(maxBudget: 15)
        let time = IssueValue.slots([T.slot(19, 20)])
        #expect(!me.permits(try Terms([.activity: .keywords([T.keyword("food")])])))
        #expect(!me.permits(try Terms([.time: .slots([T.slot(19, 20), T.slot(21, 22)])])))
        #expect(!me.permits(try Terms([.time: time, .place: .keywords([T.keyword("home")])])))
        #expect(!me.permits(try Terms([.time: time, .activity: .keywords([])])))
        #expect(!me.permits(try Terms([.time: time, .budget: .flag(true)])))
    }

    // MARK: Answers

    @Test func withoutLikedActivitiesEveryCandidateButAvoidedOnesIsAcceptable() throws {
        let me = try profile(avoided: ["sushi"])
        #expect(!me.needsModelToMatch)
        let answer = me.acceptableActivities(candidates: ["sushi", "tacos", "boba"].map(T.keyword), matches: [])
        #expect(answer == ["tacos", "boba"].map(T.keyword))
    }

    @Test func modelMatchesAreFilteredByCode() throws {
        let me = try profile(liked: ["food", "boba"], avoided: ["sushi"])
        #expect(me.needsModelToMatch)
        let candidates = ["movie", "boba", "sushi", "boba run"].map(T.keyword)
        let matches = [
            KeywordMatch(wanted: T.keyword("food"), offered: T.keyword("boba run"), strength: .satisfies),
            // Avoided: code drops it whatever the model says.
            KeywordMatch(wanted: T.keyword("food"), offered: T.keyword("sushi"), strength: .satisfies),
            // Invented: not a candidate.
            KeywordMatch(wanted: T.keyword("food"), offered: T.keyword("pizza"), strength: .satisfies),
            // Not something the owner wants.
            KeywordMatch(wanted: T.keyword("movie"), offered: T.keyword("movie"), strength: .equivalent),
        ]
        // "boba" is an exact match even though the model missed it.
        #expect(me.acceptableActivities(candidates: candidates, matches: matches) == ["boba", "boba run"].map(T.keyword))
    }

    @Test func budgetAnswerIsTheLowerCap() throws {
        #expect(try profile(maxBudget: 15).budgetAnswer(for: T.usd(20)) == T.usd(15))
        #expect(try profile(maxBudget: 15).budgetAnswer(for: T.usd(10)) == T.usd(10))
        #expect(try profile().budgetAnswer(for: T.usd(10)) == T.usd(10))
        #expect(try profile(maxBudget: 15).budgetAnswer(for: try MoneyAmount(minorUnits: 100, currency: "EUR")) == nil)
    }

    // MARK: Offers

    @Test func openingPlanTakesTheFirstOverlapBlockCappedInLength() throws {
        let me = try profile(liked: ["food", "boba"], maxBudget: 15)
        let overlap = [T.slot(20, 20.5), T.slot(20.5, 21), T.slot(21, 21.5), T.slot(21.5, 22), T.slot(22, 22.5), T.slot(19, 19.5)]
        let plan = me.openingPlan(overlap: overlap.shuffled(), activities: ["boba"].map(T.keyword), budget: T.usd(12), maxMinutes: 120, now: T.now)
        // 19:00 to 19:30 is the first block on its own.
        #expect(plan == (try T.plan(time: T.slot(19, 19.5), activity: ["boba"], budget: 12)))
        let later = me.openingPlan(overlap: Array(overlap.dropLast()), activities: nil, budget: nil, maxMinutes: 120, now: T.now)
        #expect(later == (try T.plan(time: T.slot(20, 22))))
    }

    @Test func openingPlanSkipsSharedSlotsThatHaveStarted() throws {
        let me = try profile()
        let overlap = [T.slot(19, 19.5), T.slot(19.5, 20), T.slot(20, 20.5)]
        let plan = me.openingPlan(overlap: overlap, activities: nil, budget: nil, maxMinutes: 120, now: T.at(19).addingTimeInterval(60))
        #expect(plan == (try T.plan(time: T.slot(19.5, 20.5))))
        #expect(me.openingPlan(overlap: overlap, activities: nil, budget: nil, maxMinutes: 120, now: T.at(20.25)) == nil)
    }

    @Test func noSharedActivityMeansNoPlan() throws {
        let me = try profile(liked: ["food"])
        #expect(me.openingPlan(overlap: [T.slot(19, 19.5)], activities: [], budget: nil, maxMinutes: 120, now: T.now) == nil)
    }

    @Test func aCompliantOfferIsAcceptable() throws {
        let me = try profile(maxBudget: 15)
        #expect(me.assess(try T.plan(time: T.slot(19, 20), budget: 10), overlap: nil, canCounter: true, now: T.now) == .acceptable(alternatives: []))
    }

    @Test func aMissingLikedActivityIsOfferedAsAnAlternative() throws {
        let me = try profile(liked: ["food"], avoided: ["sushi"])
        let offer = try T.plan(time: T.slot(19, 20))
        #expect(me.assess(offer, overlap: nil, canCounter: true, now: T.now) == .acceptable(alternatives: [try T.plan(time: T.slot(19, 20), activity: ["food"])]))
        #expect(me.assess(offer, overlap: nil, canCounter: false, now: T.now) == .acceptable(alternatives: []))
    }

    @Test func overBudgetIsRepairedToTheCap() throws {
        let me = try profile(maxBudget: 15)
        #expect(me.assess(try T.plan(time: T.slot(19, 20), budget: 30), overlap: nil, canCounter: true, now: T.now) == .repair(try T.plan(time: T.slot(19, 20), budget: 15)))
        let euros = try Terms([.time: .slots([T.slot(19, 20)]), .budget: .amount(try MoneyAmount(minorUnits: 500, currency: "EUR"))])
        #expect(me.assess(euros, overlap: nil, canCounter: true, now: T.now) == .repair(try T.plan(time: T.slot(19, 20), budget: 15)))
    }

    @Test func avoidedActivitiesAreDroppedOrTheOfferIsRejected() throws {
        let me = try profile(avoided: ["sushi"])
        #expect(me.assess(try T.plan(time: T.slot(19, 20), activity: ["sushi", "tacos"]), overlap: nil, canCounter: true, now: T.now)
            == .repair(try T.plan(time: T.slot(19, 20), activity: ["tacos"])))
        #expect(me.assess(try T.plan(time: T.slot(19, 20), activity: ["sushi"]), overlap: nil, canCounter: true, now: T.now) == .reject(.noOverlap))
    }

    @Test func aTimeThatRunsPastAvailabilityIsShortened() throws {
        let me = try profile(time: [T.slot(19, 20)])
        #expect(me.assess(try T.plan(time: T.slot(19, 21)), overlap: nil, canCounter: true, now: T.now) == .repair(try T.plan(time: T.slot(19, 20))))
        #expect(me.assess(try T.plan(time: T.slot(21, 22)), overlap: nil, canCounter: true, now: T.now) == .reject(.noOverlap))
    }

    @Test func aViolatingOfferInTheLastRoundIsRejected() throws {
        let me = try profile(maxBudget: 15)
        #expect(me.assess(try T.plan(time: T.slot(19, 20), budget: 30), overlap: nil, canCounter: false, now: T.now) == .reject(.tooManyRounds))
    }

    @Test func anOfferThatHasAlreadyStartedIsRejected() throws {
        let me = try profile()
        let offer = try T.plan(time: T.slot(19, 21))
        #expect(me.assess(offer, overlap: nil, canCounter: true, now: T.at(19)) == .acceptable(alternatives: []))
        #expect(me.assess(offer, overlap: nil, canCounter: true, now: T.at(19.5)) == .reject(.expired))
        // Within the start minute still counts as ahead; the next minute does not.
        #expect(me.hasNotStarted(offer, now: T.at(19).addingTimeInterval(59)))
        #expect(!me.hasNotStarted(offer, now: T.at(19).addingTimeInterval(60)))
    }

    @Test func malformedOffersAreRejected() throws {
        let me = try profile()
        #expect(me.assess(try Terms([.time: .slots([])]), overlap: nil, canCounter: true, now: T.now) == .reject(.unsupported))
    }

    // MARK: Level

    @Test func levelTravelsOnlyInsideAnAcceptance() throws {
        let plan = try T.plan(time: T.slot(19, 20), activity: ["food"])
        let maybe = try profile(level: .maybe)
        let accepted = maybe.accepting(plan)
        #expect(accepted[DownProfile.levelKey] == .keywords([T.keyword("maybe")]))
        #expect(DownProfile.split(accepted)?.plan == plan)
        #expect(DownProfile.split(accepted)?.level == .maybe)
        #expect(DownProfile.split(plan) == nil)
        var forged = accepted.values
        forged[DownProfile.levelKey] = .keywords([T.keyword("yes")])
        #expect(DownProfile.split(try Terms(forged)) == nil)
    }

    @Test func downAndMaybeHaveTheSameSlots() throws {
        #expect(try profile(level: .down).tokens.slots == profile(level: .maybe).tokens.slots)
    }
}
