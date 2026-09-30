import Foundation
import FoundationModels
@testable import StarlingAgent
import StarlingCore
import Testing

@Suite struct DecisionSchemaTests {
    static func timeOnly() throws -> NegotiationContext {
        let constraints = try ConstraintSet([.time: [try Constraint(.within([try AgentFixtures.slot(13, 17)]))]])
        let proposal = try Proposal(round: 0, terms: Terms([.time: .slots([try AgentFixtures.slot(9, 11)])]))
        return NegotiationContext(proposal: proposal, constraints: constraints, history: [], now: AgentFixtures.now)
    }

    /// The Phase 0 parent-student failure: a time-only negotiation answered
    /// with "activity option 2". The schema now has no activity field.
    @Test func timeOnlyNegotiationHasNoActivityOrBudgetField() throws {
        let context = try Self.timeOnly()
        let prompt = PromptRenderer.decide(context, timeZone: AgentFixtures.utc)
        let schema = try DecisionSchema(prompt: prompt, proposal: context.proposal)
        #expect(schema.properties == ["brokenItems", "move", "timeOption"])

        // Even if a model produced an activity number, it is never read.
        let content = GeneratedContent(properties: ["move": "counter", "timeOption": 1, "activityOption": 2])
        #expect(try schema.move(from: content) == RawMove(kind: .counter, timeOption: 1))
    }

    @Test func threeIssueProposalHasAFieldPerIssue() throws {
        let context = try AgentFixtures.context()
        let schema = try DecisionSchema(prompt: PromptRenderer.decide(context, timeZone: AgentFixtures.utc), proposal: context.proposal)
        #expect(schema.properties == ["brokenItems", "move", "timeOption", "activityOption", "budgetDollars"])
        let content = GeneratedContent(properties: ["move": "counter", "activityOption": 1, "budgetDollars": 12])
        #expect(try schema.move(from: content) == RawMove(kind: .counter, activityOption: 1, budgetDollars: 12))
    }

    @Test func unknownMoveIsInvalidOutput() throws {
        let context = try Self.timeOnly()
        let schema = try DecisionSchema(prompt: PromptRenderer.decide(context, timeZone: AgentFixtures.utc), proposal: context.proposal)
        #expect(throws: AgentModelError.self) { _ = try schema.move(from: GeneratedContent(properties: ["move": "walk away"])) }
    }
}
