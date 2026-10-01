import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

/// Lane F's answers to lane H: what the Down review must show and how
/// setIntent's own errors keep it open.
@MainActor
@Suite struct DownReviewNotesTests {
    struct NoTime: Error {}

    func model(service: any DownService = ScriptedDownService(), matchingIsPrivate: Bool = false, standing: OwnerRules? = nil,
               describe: @escaping @Sendable (any Error) -> String? = { _ in nil }) -> DownModel {
        DownModel(
            service: service,
            interpreter: RulesInterpreter(agent: nil, issues: RulesInterpreter.intentIssues),
            rules: InMemoryRulesStore(standing.map { SavedRules(rules: $0, savedAt: Fixtures.noon) }),
            peers: InMemoryPairedPeerStore(),
            notifier: RecordingNotifier(),
            matchingIsPrivate: matchingIsPrivate,
            describeError: describe
        )
    }

    @Test func aServiceErrorKeepsTheReviewOpenWithTheAppsMessage() async {
        let model = model(service: FailingDownService(NoTime()), describe: { $0 is NoTime ? "No free half-hour." : nil })
        await model.editByHand()
        await model.goDown()
        #expect(model.phase == .reviewing)
        #expect(model.notice == "No free half-hour.")
        #expect(model.active == nil)
    }

    @Test func neverSharingTimeWarnsThatDownCannotRun() async {
        let model = model()
        await model.editByHand()
        #expect(model.sharingWarnings.isEmpty)
        model.setSharing(.never, for: .time)
        #expect(model.sharingWarnings.count == 1)
        #expect(model.sharingWarnings.first?.contains("can't check with anyone") == true)
    }

    @Test func neverSharingActivityOrBudgetWarnsThatChecksEndWithoutAMatch() async {
        let model = model(standing: OwnerRules(constraints: .empty, disclosure: [DisclosureRule(issue: .budget, action: .never)]))
        await model.editByHand()
        model.setSharing(.never, for: .activity)
        let warning = model.sharingWarnings.joined()
        #expect(warning.contains("Activity"))
        #expect(warning.contains("Budget"))
        #expect(warning.contains("without a match"))
    }

    @Test func saysWhenMatchingDoesNotHideFreeTimes() async {
        #expect(model(matchingIsPrivate: false).matchingNote != nil)
        #expect(model(matchingIsPrivate: true).matchingNote == nil)
    }
}
