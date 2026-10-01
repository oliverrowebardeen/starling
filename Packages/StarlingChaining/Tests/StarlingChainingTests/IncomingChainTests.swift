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
}
