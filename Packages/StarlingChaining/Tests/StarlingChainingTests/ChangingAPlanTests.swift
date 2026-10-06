import Foundation
import StarlingChaining
import StarlingCore
import StarlingFakes
import Testing

@Suite struct ChangingAPlanTests {
    let registry = try! SkillRegistry(SampleSkills.all + [Fixtures.changePlan])
    var planner: ChainPlanner { ChainPlanner(registry: registry, me: Fixtures.me) }
    let settings = Fixtures.withChangePlan
    let cards = Fixtures.cards(SampleSkills.all + [Fixtures.changePlan])
    let now = Fixtures.date(minutes: 30)
    let tap = OwnerTap(at: Fixtures.at(minutes: 30))
    let expiry = Fixtures.at(minutes: 60)

    @Test func aStandingPlanOffersAChangeToEveryoneElseInIt() throws {
        let plan = try Fixtures.plannedDownFor()
        let row = try #require(planner.changeOffer(for: plan.id, in: [plan], settings: settings, cards: cards, now: now))
        #expect(row.trigger == .whilePlanned)
        #expect(row.participants == [Fixtures.maya, Fixtures.jake])
        #expect(row.parentConversation == plan.planConversation)
        // Down for… already covers time and activity; people is new.
        #expect(row.adds == SkillExposure(topics: [.people]))
        // Never under "Keep it going".
        #expect(!planner.suggestions(after: plan.id, in: [plan], settings: settings, cards: cards).contains { $0.id == .changePlan })
    }

    @Test func noChangeIsOfferedWhenThePlanCannotTakeOne() throws {
        let plan = try Fixtures.plannedDownFor()
        // Ended.
        #expect(planner.changeOffer(for: plan.id, in: [plan], settings: settings, cards: cards, now: Fixtures.tonight.end) == nil)
        // Flagged off.
        let flaggedOff = SkillFlags(SkillFlags.phase1_5.enabled.subtracting([.changePlan]))
        #expect(planner.changeOffer(for: plan.id, in: [plan], settings: SkillSettings(flags: flaggedOff), cards: cards, now: now) == nil)
        // Jake's Starling does not run it.
        var missing = cards
        missing[Fixtures.jake] = Fixtures.card(SampleSkills.all)
        #expect(planner.changeOffer(for: plan.id, in: [plan], settings: settings, cards: missing, now: now) == nil)
        // At the revision limit.
        var worn = plan
        worn.record(.plan(try Plan(origin: plan.conversation, attendees: try #require(plan.plan).attendees, activity: Fixtures.boba,
                                   time: Fixtures.tonight, revision: ChainPlanner.maxChangeableRevision)))
        #expect(planner.changeOffer(for: worn.id, in: [worn], settings: settings, cards: cards, now: now) == nil)
    }

    @Test func oneOpenSuggestionPerPlan() throws {
        let plan = try Fixtures.plannedDownFor()
        let row = try #require(planner.changeOffer(for: plan.id, in: [plan], settings: settings, cards: cards, now: now))
        let mine = try planner.beginChange(row, in: [plan], settings: settings, cards: cards, now: now, tap: tap,
                                           consent: row.consent(approvedAt: tap.at), rules: .empty, extraInputs: [], expiresAt: expiry).interaction
        #expect(planner.changeOffer(for: plan.id, in: [plan, mine], settings: settings, cards: cards, now: now) == nil)
        // A friend's open suggestion, grouped under the plan, blocks too.
        var theirs = Interaction(skill: Fixtures.changePlan.ref, role: .invitee, participants: [Fixtures.maya], createdAt: Fixtures.at(minutes: 31))
        try theirs.setFriendChainHint(plan.planConversation)
        #expect(planner.changeOffer(for: plan.id, in: [plan, theirs], settings: settings, cards: cards, now: now) == nil)
        // Once it settles, a new one can start.
        try theirs.apply(.expired, at: Fixtures.at(minutes: 40))
        #expect(planner.changeOffer(for: plan.id, in: [plan, theirs], settings: settings, cards: cards, now: now) != nil)
    }

    @Test func aSuggestionIsALinkThatCarriesThePlanAndTheChange() throws {
        let plan = try Fixtures.plannedDownFor()
        let row = try #require(planner.changeOffer(for: plan.id, in: [plan], settings: settings, cards: cards, now: now))
        #expect(throws: ChainError.consentRequired(SkillExposure(topics: [.people]))) {
            try planner.beginChange(row, in: [plan], settings: settings, cards: cards, now: now, tap: tap, consent: nil, rules: .empty,
                                    extraInputs: [], expiresAt: expiry)
        }
        let later = try TimeSlot(start: Fixtures.date(minutes: 120), end: Fixtures.date(minutes: 240))
        let rules = OwnerRules(constraints: try ConstraintSet([.time: [try Constraint(.within([later]))]]))
        let start = try planner.beginChange(row, in: [plan], settings: settings, cards: cards, now: now, tap: tap,
                                            consent: row.consent(approvedAt: tap.at), rules: rules, extraInputs: [], expiresAt: expiry)
        #expect(start.interaction.chain == ChainLink(parent: plan.id, parentConversation: plan.planConversation, consumed: [.plan],
                                                     trigger: .whilePlanned, optedInAt: tap.at))
        #expect(start.request.chainedFrom == plan.planConversation)
        #expect(start.request.inputs == [.plan(try #require(plan.plan))])
        #expect(start.request.intent.rules == rules)
        #expect(start.request.intent.mode == .invite)
        #expect(start.request.participants == [Fixtures.maya, Fixtures.jake])
    }

    @Test func onlyAFriendOfThisPhoneCanBeAdded() throws {
        let plan = try Fixtures.plannedDownFor()
        let row = try #require(planner.changeOffer(for: plan.id, in: [plan], settings: settings, cards: cards, now: now))
        let consent = row.consent(approvedAt: tap.at)
        func add(_ roster: [PeerID], cards: [PeerID: AgentCard]) throws -> ChainStart {
            try planner.beginChange(row, in: [plan], settings: settings, cards: cards, now: now, tap: tap, consent: consent, rules: .empty,
                                    extraInputs: [.attendees(try Attendees(roster))], expiresAt: expiry)
        }
        var withSam = cards
        withSam[Fixtures.stranger] = Fixtures.card(SampleSkills.all + [Fixtures.changePlan])
        let start = try add([Fixtures.me, Fixtures.maya, Fixtures.jake, Fixtures.stranger], cards: withSam)
        #expect(start.request.inputs.last == .attendees(try Attendees([Fixtures.me, Fixtures.maya, Fixtures.jake, Fixtures.stranger])))
        // Not a friend here (no card); someone already in it; or a removal.
        #expect(throws: ChainError.cannotAdd) { try add([Fixtures.me, Fixtures.maya, Fixtures.jake, Fixtures.stranger], cards: cards) }
        #expect(throws: ChainError.cannotAdd) { try add([Fixtures.me, Fixtures.maya], cards: withSam) }
        #expect(throws: ChainError.cannotAdd) { try add([Fixtures.me, Fixtures.jake, Fixtures.maya, Fixtures.stranger], cards: withSam) }
    }

    @Test func leavingNeedsNoAgreementOrConsent() throws {
        let plan = try Fixtures.plannedDownFor()
        // Even with Jake lacking the skill, and a suggestion open.
        var theirs = Interaction(skill: Fixtures.changePlan.ref, role: .invitee, participants: [Fixtures.maya], createdAt: Fixtures.at(minutes: 31))
        try theirs.setFriendChainHint(plan.planConversation)
        let start = try planner.beginLeave(from: plan.id, in: [plan, theirs], settings: settings, tap: tap, rules: .empty, expiresAt: expiry)
        #expect(start.interaction.chain?.trigger == .whilePlanned)
        #expect(start.request.participants == [Fixtures.maya, Fixtures.jake])
        #expect(start.request.chainedFrom == plan.planConversation)
        // Not from a plan that is not standing.
        var ended = plan
        try ended.apply(.planEnded, at: Fixtures.at(minutes: 300))
        #expect(throws: ChainError.notOffered(.changePlan)) {
            try planner.beginLeave(from: ended.id, in: [ended], settings: settings, tap: tap, rules: .empty, expiresAt: expiry)
        }
    }
}
