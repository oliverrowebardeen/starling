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
        #expect(schema.properties == ["move", "timeOption"])

        // Even if a model produced an activity number, it is never read.
        let content = GeneratedContent(properties: ["move": "counter", "timeOption": 1, "activityOption": 2])
        #expect(try schema.move(from: content) == RawMove(kind: .counter, timeOption: 1))
    }

    @Test func threeIssueProposalHasAFieldPerIssue() throws {
        let context = try AgentFixtures.context()
        let schema = try DecisionSchema(prompt: PromptRenderer.decide(context, timeZone: AgentFixtures.utc), proposal: context.proposal)
        #expect(schema.properties == ["move", "timeOption", "activityOption", "budgetDollars"])
        let content = GeneratedContent(properties: ["move": "counter", "activityOption": 1, "budgetDollars": 12])
        #expect(try schema.move(from: content) == RawMove(kind: .counter, activityOption: 1, budgetDollars: 12))
    }

    @Test func unknownMoveIsInvalidOutput() throws {
        let context = try Self.timeOnly()
        let schema = try DecisionSchema(prompt: PromptRenderer.decide(context, timeZone: AgentFixtures.utc), proposal: context.proposal)
        #expect(throws: AgentModelError.self) { _ = try schema.move(from: GeneratedContent(properties: ["move": "walk away"])) }
    }

    /// Hard limits in code (ARCHITECTURE rule 6): terms that break one are
    /// never offered to accept, a counter must fix every broken issue, and
    /// the budget cannot leave the owner's range.
    @Test func brokenProposalCannotBeAcceptedAndCounterMustFixIt() throws {
        let context = try AgentFixtures.context()
        let prompt = PromptRenderer.decide(context, timeZone: AgentFixtures.utc)
        let schema = try DecisionSchema(prompt: prompt, proposal: context.proposal)
        #expect(schema.moves == ["counter", "reject"])
        #expect(throws: AgentModelError.self) { _ = try schema.move(from: GeneratedContent(properties: ["move": "accept"])) }
        let text = schema.schema.debugDescription
        #expect(text.contains("budgetDollars"))
    }

    @Test func compliantProposalWithPreferencesOffersEveryMove() throws {
        let constraints = try ConstraintSet([
            .time: [try Constraint(.within([try AgentFixtures.slot(8, 20)]))],
            .activity: [try Constraint(.prefers(liked: [try Keyword("boba")], avoided: []), strength: .soft)],
        ])
        let proposal = try Proposal(round: 0, terms: Terms([.time: .slots([try AgentFixtures.slot(9, 11)]), .activity: .keywords([try Keyword("tacos")])]))
        let context = NegotiationContext(proposal: proposal, constraints: constraints, history: [], now: AgentFixtures.now)
        let schema = try DecisionSchema(prompt: PromptRenderer.decide(context, timeZone: AgentFixtures.utc), proposal: proposal)
        #expect(schema.moves == DecisionSchema.moves)
    }

    /// Hard limits only, all met: every compliant term is as good as any
    /// other, so the bench saw the model counter forever. Accept, no call.
    @Test func compliantProposalWithoutPreferencesIsAcceptedWithoutTheModel() async throws {
        let constraints = try ConstraintSet([.time: [try Constraint(.within([try AgentFixtures.slot(8, 20)]))]])
        let proposal = try Proposal(round: 0, terms: Terms([.time: .slots([try AgentFixtures.slot(9, 11)])]))
        let context = NegotiationContext(proposal: proposal, constraints: constraints, history: [], now: AgentFixtures.now)
        let schema = try DecisionSchema(prompt: PromptRenderer.decide(context, timeZone: AgentFixtures.utc), proposal: proposal)
        #expect(schema.moves == ["accept"])
        let result = try await FoundationModelsAgent(timeZone: AgentFixtures.utc).decide(context)
        #expect(result.value == .accept)
    }

    /// A broken issue no counter field can fix leaves only reject, which
    /// needs no model call at all.
    @Test func unfixableProposalIsRejectedWithoutTheModel() async throws {
        let constraints = try ConstraintSet([.partySize: [try Constraint(.countBetween(min: 2, max: 4))]])
        let proposal = try Proposal(round: 0, terms: Terms([.partySize: .count(9)]))
        let context = NegotiationContext(proposal: proposal, constraints: constraints, history: [], now: AgentFixtures.now)
        let schema = try DecisionSchema(prompt: PromptRenderer.decide(context, timeZone: AgentFixtures.utc), proposal: proposal)
        #expect(schema.moves == ["reject"])
        let result = try await FoundationModelsAgent(timeZone: AgentFixtures.utc).decide(context)
        #expect(result.value == .reject(.noOverlap))
        #expect(result.usage == TokenUsage(inputTokens: 0, outputTokens: 0))
    }

    @Test func budgetRangeRoundsInward() throws {
        let constraints = try ConstraintSet([.budget: [
            try Constraint(.atMost(try MoneyAmount(minorUnits: 1250))),
            try Constraint(.atLeast(try MoneyAmount(minorUnits: 550))),
        ]])
        #expect(PromptRenderer.budgetRange(constraints) == 6...12)
        let impossible = try ConstraintSet([.budget: [
            try Constraint(.atMost(try MoneyAmount(minorUnits: 500))),
            try Constraint(.atLeast(try MoneyAmount(minorUnits: 900))),
        ]])
        #expect(PromptRenderer.budgetRange(impossible) == nil)
    }
}
