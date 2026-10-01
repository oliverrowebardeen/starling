import Foundation
import StarlingCore
import StarlingPolicy
import Testing

/// ADR 0019 decision 4: a yes or no to a friend's own candidates carries no
/// value of the owner's, so Never and Ask me do not stop it. Anything else
/// in an answer is judged by its topic as before.
@Suite struct YesOrNoAnswerTests {
    static let boba = try! Keyword("boba")
    static let tea = try! Keyword("tea")
    static let coffee = try! Keyword("coffee")
    static let query = try! Query(issue: .activity, candidates: .keywords([boba, tea]))

    static func answer(_ keywords: [Keyword], issue: IssueKey = .activity) throws -> MessageBody {
        .answer(try Answer(query: Fixtures.queryID, issue: issue, status: .answered, acceptable: .keywords(keywords)))
    }

    @Test(arguments: [DisclosureRule.Action.never, .askEachTime, .allowOnDevicePeers])
    func aYesOrNoToTheFriendsCandidatesGoesUnderEveryChoice(action: DisclosureRule.Action) async throws {
        let engine = Fixtures.engine(action: action)
        for yes in [[Self.boba], [Self.boba, Self.tea], []] {
            let message = try Fixtures.outbound(Self.answer(yes), context: OutboundContext(answering: Self.query))
            #expect(await engine.evaluate(message) == .allow)
        }
    }

    @Test func withoutTheQueryAnAnswerIsJudgedByItsTopic() async throws {
        let message = try Fixtures.outbound(Self.answer([Self.boba]))
        #expect(await Fixtures.engine(action: .never).evaluate(message) == .deny(PolicyViolation(rule: PolicyRuleID.never, issue: .activity)))
    }

    @Test func aValueTheFriendNeverOfferedIsTheOwnersAndIsJudgedByItsTopic() async throws {
        let engine = Fixtures.engine(action: .never)
        let added = try Fixtures.outbound(Self.answer([Self.boba, Self.coffee]), context: OutboundContext(answering: Self.query))
        #expect(await engine.evaluate(added) == .deny(PolicyViolation(rule: PolicyRuleID.never, issue: .activity)))
        let otherIssue = try Fixtures.outbound(
            .answer(try Answer(query: Fixtures.queryID, issue: .budget, status: .answered, acceptable: .keywords([Self.boba]))),
            context: OutboundContext(answering: Self.query)
        )
        #expect(await Fixtures.engine(action: .allowOnDevicePeers).evaluate(otherIssue) != .allow)
    }

    @Test func aCloudAgentStillNeedsTheOwnersOK() async throws {
        let engine = Fixtures.engine(action: .never)
        let message = try Fixtures.outbound(Self.answer([Self.boba]), card: AgentCard(model: .thirdPartyCloud(provider: "example"), capabilities: []),
                                            context: OutboundContext(answering: Self.query))
        #expect(await engine.evaluate(message) == .needsConsent(try engine.disclosure(for: message)))
    }

    @Test func singleValuesAreYesOnlyWhenEqual() throws {
        let price = try MoneyAmount(minorUnits: 2_000, currency: "USD")
        let query = try Query(issue: .budget, candidates: .amount(price))
        let same = try Answer(query: MessageID(), issue: .budget, status: .answered, acceptable: .amount(price))
        let other = try Answer(query: MessageID(), issue: .budget, status: .answered,
                               acceptable: .amount(try MoneyAmount(minorUnits: 1_500, currency: "USD")))
        let declined = try Answer(query: MessageID(), issue: .budget, status: .declined)
        #expect(query.isAnsweredYesOrNo(by: same))
        #expect(!query.isAnsweredYesOrNo(by: other))
        #expect(query.isAnsweredYesOrNo(by: declined))
    }

    /// Lane D's request 12: with Place set to Never, a friend could say yes
    /// on a list but not accept the plan that came of it.
    @Test(arguments: [DisclosureRule.Action.never, .askEachTime])
    func acceptingExactlyWhatTheFriendProposedIsAYes(action: DisclosureRule.Action) async throws {
        let engine = Fixtures.engine(action: action)
        let offered = try Proposal(round: 0, terms: Fixtures.terms)
        let yes = MessageBody.accept(Acceptance(proposal: Fixtures.queryID, terms: offered.terms))
        let accepted = try Fixtures.outbound(yes, context: OutboundContext(accepting: offered))
        #expect(await engine.evaluate(accepted) == .allow)

        // Without the proposal, or with terms the friend never proposed, the
        // acceptance is judged by its topics as before.
        #expect(await engine.evaluate(try Fixtures.outbound(yes)) != .allow)
        let changed = try Terms([.activity: .keywords([Self.coffee])])
        let other = try Fixtures.outbound(.accept(Acceptance(proposal: Fixtures.queryID, terms: changed)),
                                          context: OutboundContext(accepting: offered))
        #expect(await engine.evaluate(other) != .allow)
    }
}
