import Foundation
import StarlingChaining
import StarlingCore
import StarlingFakes
import Testing

@Suite struct IncomingChainTests {
    @Test func aHintGroupsOnlyUnderAPlanTheSenderIsIn() throws {
        let plan = try Fixtures.plannedDownFor()
        #expect(IncomingChain.timelineParent(chainedFrom: plan.conversation, sender: Fixtures.maya, interactions: [plan]) == plan.conversation)
        // Someone who was never in the plan.
        #expect(IncomingChain.timelineParent(chainedFrom: plan.conversation, sender: Fixtures.stranger, interactions: [plan]) == nil)
        // A conversation this phone does not know, or none at all.
        #expect(IncomingChain.timelineParent(chainedFrom: ConversationID(), sender: Fixtures.maya, interactions: [plan]) == nil)
        #expect(IncomingChain.timelineParent(chainedFrom: nil, sender: Fixtures.maya, interactions: [plan]) == nil)
    }

    @Test func aHintNeverAttachesToSomethingThatIsNotAPlan() throws {
        var asked = Interaction(skill: SampleSkills.downFor.ref, role: .invitee, participants: [Fixtures.maya], createdAt: Fixtures.at(minutes: 0))
        let terms = try Terms([.activity: .keywords([Fixtures.boba])])
        try asked.apply(.proposalReady(SkillProposal(revision: 1, participants: [Fixtures.me, Fixtures.maya], terms: terms)), at: Fixtures.at(minutes: 1))
        #expect(IncomingChain.timelineParent(chainedFrom: asked.conversation, sender: Fixtures.maya, interactions: [asked]) == nil)
    }

    @Test func someoneAskedButNotInThePlanCannotAttachARequest() throws {
        // Issue #67: you asked Maya and Jake; only Maya made the plan.
        var asked = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [Fixtures.maya, Fixtures.jake],
                                createdAt: Fixtures.at(minutes: 0))
        try asked.apply(.started, at: Fixtures.at(minutes: 1))
        let plan = try Plan(origin: asked.conversation, attendees: Attendees([Fixtures.me, Fixtures.maya]), activity: Fixtures.boba, time: Fixtures.tonight)
        let terms = try Terms([.activity: .keywords([Fixtures.boba])])
        try asked.apply(.proposalReady(SkillProposal(revision: 1, participants: plan.attendees.peers, terms: terms, plan: plan)), at: Fixtures.at(minutes: 2))
        try asked.apply(.ownerAccepted(revision: 1), at: Fixtures.at(minutes: 3))
        try asked.apply(.everyoneConfirmed(revision: 1), at: Fixtures.at(minutes: 4))
        asked.record(.plan(plan))
        #expect(IncomingChain.timelineParent(chainedFrom: asked.conversation, sender: Fixtures.jake, interactions: [asked]) == nil)
        #expect(IncomingChain.timelineParent(chainedFrom: asked.conversation, sender: Fixtures.maya, interactions: [asked]) == asked.conversation)
        #expect(IncomingChain.timelineParent(chainedFrom: ConversationID(), sender: Fixtures.maya, interactions: [asked]) == nil)
    }

    /// A friend added to a plan later (ADR 0022) holds it in an interaction
    /// of their own conversation; the plan's origin still names it.
    @Test func aPlanHeldOutsideItsOriginConversationIsNamedByItsOrigin() throws {
        let origin = ConversationID()
        var joined = Interaction(skill: SkillRef(.changePlan, SkillVersion(1)), role: .invitee, participants: [Fixtures.maya],
                                 createdAt: Fixtures.at(minutes: 0))
        let plan = try Plan(origin: origin, attendees: Attendees([Fixtures.me, Fixtures.maya, Fixtures.jake]), activity: Fixtures.boba,
                            time: Fixtures.tonight, revision: 1)
        let terms = try Terms([.activity: .keywords([Fixtures.boba])])
        for event in [InteractionEvent.proposalReady(SkillProposal(revision: 1, participants: plan.attendees.peers, terms: terms, plan: plan)),
                      .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try joined.apply(event, at: Fixtures.at(minutes: 1))
        }
        joined.record(.plan(plan))
        #expect(joined.planConversation == origin)
        #expect(joined.planConversation != joined.conversation)
        // Jake's request chained to the plan groups under it.
        #expect(IncomingChain.timelineParent(chainedFrom: origin, sender: Fixtures.jake, interactions: [joined]) == origin)
        #expect(IncomingChain.timelineParent(chainedFrom: joined.conversation, sender: Fixtures.jake, interactions: [joined]) == nil)
        // And a chain started here names the origin.
        let changePlan = try SkillDescriptor(
            ref: SkillRef(.changePlan, SkillVersion(1)), wording: SampleSkills.pickAPlace.wording, buildingBlock: .negotiationWithPrivateLimits,
            topicsUsed: [.time, .activity], topicsRequired: [], accepts: [.plan], produces: [.plan],
            intent: try IntentSchema(slots: [IntentSlot(.time, required: false, hint: "the new time")]), chainTrigger: .whilePlanned
        )
        let planner = ChainPlanner(registry: try SkillRegistry(SampleSkills.all + [changePlan]), me: Fixtures.me)
        let rows = planner.suggestions(after: joined.id, in: [joined], settings: SkillSettings(flags: .phase1_5),
                                       cards: Fixtures.cards(SampleSkills.all + [changePlan]))
        #expect(rows.map(\.id) == [.pickAPlace])
        #expect(rows.allSatisfy { $0.parentConversation == origin })
    }
}
