import Foundation
@testable import StarlingAgentBench
import StarlingCore
import StarlingFakes
import Testing

@Suite struct MatchSetTests {
    @Test func labelsAreValidKeywordsWithNegativeControls() throws {
        for label in MatchSet.labels {
            _ = try label.wanted.map { try Keyword($0) }
            _ = try label.offered.map { try Keyword($0) }
            for (want, offers) in label.satisfies {
                #expect(label.wanted.contains(want), "\(label.name)")
                #expect(Set(offers).isSubset(of: label.offered), "\(label.name)")
            }
        }
        #expect(MatchSet.labels.contains { $0.name == "food-vs-movie" && $0.isNegativeControl })
        #expect(MatchSet.labels.filter(\.isNegativeControl).count >= 10)
    }

    /// A model that answers every labeled case perfectly scores perfectly.
    @Test func oracleIsFullyCorrect() async {
        let oracle = ScriptedAgentModel(onMatch: { wanted, offered in
            guard let label = MatchSet.labels.first(where: { $0.wanted == wanted.map(\.value) && $0.offered == offered.map(\.value) }) else { return [] }
            return wanted.compactMap { want in
                guard let offer = label.satisfies[want.value]?.first else { return nil }
                return KeywordMatch(wanted: want, offered: try! Keyword(offer), strength: .satisfies)
            }
        })
        let report = await MatchEval(model: oracle).run()
        #expect(report.correct == MatchSet.labels.count)
        #expect(report.negativeControlsMatched == 0)
        #expect(report.missedWants == 0)
    }

    /// Issue #9's failure: every want matches every offer.
    @Test func matchEverythingFailsEveryNegativeControl() async {
        let greedy = ScriptedAgentModel(onMatch: { wanted, offered in
            wanted.flatMap { w in offered.map { KeywordMatch(wanted: w, offered: $0, strength: .equivalent) } }
        })
        let report = await MatchEval(model: greedy).run()
        #expect(report.negativeControlsMatched == report.negativeControls)
        #expect(report.missedWants == 0)
        #expect(report.markdown().contains("| Negative controls with a false match | \(report.negativeControls) / \(report.negativeControls) | 100% |"))
    }

    /// Exact matching alone never false-matches but misses every fuzzy want.
    @Test func exactMatchingMissesFuzzyWants() async {
        let report = await MatchEval(model: ScriptedAgentModel()).run()
        #expect(report.falseMatches == 0)
        #expect(report.missedWants == report.positiveWants)
    }
}
