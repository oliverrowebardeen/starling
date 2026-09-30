import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

@Suite struct SharingRowTests {
    @Test func everyDisclosableIssueHasARowEvenWhenTheRulesSayNothing() {
        let rows = RulesDraft.empty.sharingRows()
        #expect(rows.map(\.issue) == RulesDraft.disclosableIssues)
        #expect(rows.allSatisfy { $0.action == .askEachTime && $0.choices.contains(.never) })
    }

    @Test func issuesTheRulesMentionGetRowsToo() throws {
        let walking = try IssueKey("walking_distance")
        var draft = RulesDraft.empty
        draft.add(.mustBe, issue: walking)
        #expect(draft.sharingRows().map(\.issue) == RulesDraft.disclosableIssues + [walking])
    }

    /// ADR 0161: "keep my location to myself" can come back with no never-share
    /// flag. The owner still sees Place and can set it.
    @Test func aMissedNeverShareCanBeSetInTheReview() throws {
        let missed = OwnerRules(constraints: try ConstraintSet([.time: [try Constraint(.dailyWindow(from: 600, to: 1440))]]))
        var draft = RulesDraft(missed, origin: .model)
        #expect(draft.sharingRows().first { $0.issue == .place }?.action == .askEachTime)

        draft.setSharing(.never, for: .place)

        #expect(draft.sharingRows().first { $0.issue == .place }?.action == .never)
        #expect(try draft.build().disclosure == [DisclosureRule(issue: .place, action: .never)])
    }

    @Test func askingEachTimeWritesNoRuleWhereThereWasNone() throws {
        var draft = RulesDraft.empty
        draft.setSharing(.askEachTime, for: .budget)
        #expect(try draft.build().disclosure.isEmpty)
        draft.setSharing(.never, for: .budget)
        draft.setSharing(.askEachTime, for: .budget)
        #expect(try draft.build().disclosure == [DisclosureRule(issue: .budget, action: .askEachTime)])
    }

    @Test func aSavedNeverIsShownOnAndCannotBeLoosened() throws {
        let standing = [DisclosureRule(issue: .place, action: .never)]
        var draft = RulesDraft.empty
        let place = try #require(draft.sharingRows(standing: standing).first { $0.issue == .place })
        #expect(place.action == .never)
        #expect(place.choices == [.never])
        #expect(place.fromSavedRules)

        draft.setSharing(.allowOnDevicePeers, for: .place, standing: standing)
        #expect(try draft.build().disclosure.isEmpty)
    }

    @Test func aSavedAskCanBeTightenedButNotLoosened() throws {
        let standing = [DisclosureRule(issue: .time, action: .askEachTime)]
        var draft = RulesDraft.empty
        #expect(draft.sharingRows(standing: standing).first { $0.issue == .time }?.choices == [.never, .askEachTime])
        draft.setSharing(.never, for: .time, standing: standing)
        #expect(draft.sharingRows(standing: standing).first { $0.issue == .time }?.action == .never)
    }

    @Test func duplicateSharingRulesCollapseToTheMostRestrictive() {
        let draft = RulesDraft(OwnerRules(constraints: .empty, disclosure: [
            DisclosureRule(issue: .place, action: .allowOnDevicePeers),
            DisclosureRule(issue: .place, action: .never),
        ]), origin: .model)
        #expect(draft.sharing.count == 1)
        #expect(draft.sharingRows().first { $0.issue == .place }?.action == .never)
    }
}

@MainActor
@Suite struct DownReviewSharingTests {
    @Test func theDownReviewShowsSavedNeverShareAndTheIntentCarriesANewOne() async throws {
        let service = ScriptedDownService()
        let standing = SavedRules(rules: OwnerRules(constraints: .empty, disclosure: [DisclosureRule(issue: .place, action: .never)]), savedAt: Fixtures.noon)
        // The model missed "keep my budget to myself".
        let interpreted = DownModelTests.intentRules
        let agent = ScriptedAgentModel(onInterpret: { _, _ in interpreted })
        let model = DownModel(
            service: service,
            interpreter: RulesInterpreter(agent: agent, issues: RulesInterpreter.intentIssues),
            rules: InMemoryRulesStore(standing),
            peers: InMemoryPairedPeerStore(),
            notifier: RecordingNotifier()
        )
        model.text = "free tonight, want food, keep my budget to myself"
        await model.interpret()

        let rows = model.sharingRows
        #expect(Set(rows.map(\.issue)).isSuperset(of: RulesDraft.disclosableIssues))
        #expect(rows.first { $0.issue == .place }?.action == .never)
        #expect(rows.first { $0.issue == .budget }?.action == .askEachTime)

        model.setSharing(.never, for: .budget)
        model.setSharing(.allowOnDevicePeers, for: .place)
        await model.goDown()

        let sent = try #require(await service.intents.first).rules.disclosure
        #expect(sent.contains(DisclosureRule(issue: .budget, action: .never)))
        #expect(sent.contains(DisclosureRule(issue: .place, action: .never)))
    }
}

/// Review finding 1 on PR #15: what a row shows must be what the merged
/// intent publishes, for every saved rule and every owner choice.
@Suite struct SharingRowAgreementTests {
    static let actions: [DisclosureRule.Action] = [.never, .askEachTime, .allowOnDevicePeers]

    /// The action the policy applies to `issue` under `rules`: no rule asks.
    static func effective(_ rules: OwnerRules, _ issue: IssueKey) -> DisclosureRule.Action {
        rules.disclosure.first { $0.issue == issue }?.action ?? .askEachTime
    }

    static func published(_ draft: RulesDraft, standing: [DisclosureRule]) throws -> OwnerRules {
        try RulesMerge.intent(try draft.build(), standing: OwnerRules(constraints: .empty, disclosure: standing))
    }

    @Test func aSavedAllowanceIsShownAsTheEffectiveAction() throws {
        let standing = [DisclosureRule(issue: .time, action: .allowOnDevicePeers)]
        var draft = RulesDraft.empty
        let row = try #require(draft.sharingRows(standing: standing).first { $0.issue == .time })
        #expect(row.action == .allowOnDevicePeers)
        #expect(row.action == Self.effective(try Self.published(draft, standing: standing), .time))

        draft.setSharing(.askEachTime, for: .time, standing: standing)
        #expect(Self.effective(try Self.published(draft, standing: standing), .time) == .askEachTime)
        #expect(draft.sharingRows(standing: standing).first { $0.issue == .time }?.action == .askEachTime)
    }

    @Test func everyRowAgreesWithThePublishedIntent() throws {
        for saved in [nil] + Self.actions.map(Optional.some) {
            let standing = saved.map { [DisclosureRule(issue: .place, action: $0)] } ?? []
            for choice in [nil] + Self.actions.map(Optional.some) {
                var draft = RulesDraft.empty
                if let choice { draft.setSharing(choice, for: .place, standing: standing) }
                let shown = try #require(draft.sharingRows(standing: standing).first { $0.issue == .place }).action
                let sent = Self.effective(try Self.published(draft, standing: standing), .place)
                #expect(shown == sent, "saved \(String(describing: saved)), chose \(String(describing: choice))")
            }
        }
    }
}
