import Foundation
@testable import StarlingAgent
import StarlingAgentBench
import StarlingCore
import StarlingFakes
import Testing

let phase15Skills = [SampleSkills.downFor, SampleSkills.findATime, SampleSkills.pickAPlace]

/// The scorers, against scripted models (ADR 0160: CI checks the wiring).
@Suite struct SkillEvalTests {
    @Test func aPerfectRouterScoresEveryLabel() async {
        let labels = RoutingSet.labels + RoutingSet.heldOut
        let answers = Dictionary(labels.map { ($0.text, $0.skill) }, uniquingKeysWith: { first, _ in first })
        let oracle = ScriptedSkillModel(onRoute: { text, _ in try answers[text]!.map(SkillID.init) })
        let report = await RoutingEval(model: oracle, skills: phase15Skills, labels: labels).run()
        #expect(report.correct == labels.count)
        #expect(report.missedRequests == 0 && report.falseRoutes == 0)
    }

    @Test func aRouterThatAlwaysPicksDownForIsCaught() async {
        let report = await RoutingEval(model: ScriptedSkillModel(onRoute: { _, _ in .downFor }), skills: phase15Skills).run()
        #expect(report.falseRoutes == RoutingSet.labels.filter { $0.skill == nil }.count)
        #expect(report.correct(for: "find_a_time").0 == 0)
    }

    @Test func everyLabelUsesASkillThatExists() {
        let ids = Set(phase15Skills.map(\.id.rawValue))
        for label in RoutingSet.labels + RoutingSet.heldOut {
            #expect(label.skill.map(ids.contains) ?? true, "\(label.text)")
        }
    }

    @Test func chipsScoreFieldByField() throws {
        let label = ChipSet.labels[0] // boba tonight with whoever's free, nothing far
        let now = InterpretationSet.now
        let tonight = try TimeSlot(start: now.addingTimeInterval(6 * 3600), end: now.addingTimeInterval(12 * 3600))
        let parsed = ParsedIntent(constraints: try ConstraintSet([
            .activity: [try Constraint(.prefers(liked: [try Keyword("boba")], avoided: []), strength: .soft)],
            .time: [try Constraint(.within([tonight]))],
            .place: [try Constraint(.prefers(liked: [try Keyword("nothing far")], avoided: []), strength: .soft)],
        ]), audience: .allFriends)
        #expect(ChipScorer.score(label, parsed: parsed, now: now, timeZone: InterpretationSet.timeZone).isExact)

        let wrong = ParsedIntent(constraints: try ConstraintSet([
            .activity: [try Constraint(.prefers(liked: [try Keyword("tea")], avoided: []), strength: .soft)],
        ]), mentionedNames: ["Maya"])
        let result = ChipScorer.score(label, parsed: wrong, now: now, timeZone: InterpretationSet.timeZone)
        #expect(result.correct == [.avoids, .budget, .mode])
        #expect(result.inventedWants == ["tea"])
    }

    @Test func chipLabelsFitTheDownForSchema() throws {
        // Every label is in New's length limit and names only slot issues.
        for label in ChipSet.labels + ChipSet.heldOut {
            _ = try OwnerUtterance(label.text)
            #expect(label.audience == nil || ["everyone", "close", "except"].contains(label.audience!))
            #expect(label.mode == nil || ["quietly", "invite"].contains(label.mode!))
        }
    }
}

/// Runs the real model on the Phase 1.5 sets. Opt in with
/// STARLING_MODEL_TESTS=1 on a Mac or an iPhone with Apple Intelligence; the
/// device checklist (docs/checklists/phase-1.5-P15-B.md) runs these on iOS 27.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STARLING_MODEL_TESTS"] == "1"))
struct LiveSkillModelTests {
    @Test(.timeLimit(.minutes(5)), arguments: [false, true])
    func routingSetScores(heldOut: Bool) async {
        let agent = FoundationModelsAgent()
        print("Variant: \(agent.variantName ?? "unknown")")
        let report = await RoutingEval(model: agent, skills: phase15Skills, labels: heldOut ? RoutingSet.heldOut : RoutingSet.labels).run()
        print(report.markdown(title: heldOut ? "Routing accuracy, held-out (live)" : "Routing accuracy (live)"))
        #expect(report.errors == 0)
    }

    @Test(.timeLimit(.minutes(5)), arguments: [false, true])
    func chipSetScores(heldOut: Bool) async {
        let agent = FoundationModelsAgent(timeZone: InterpretationSet.timeZone)
        let report = await ChipEval(model: agent, skills: SampleSkills.all, labels: heldOut ? ChipSet.heldOut : ChipSet.labels).run()
        print(report.markdown(title: heldOut ? "Down for... chips, held-out (live)" : "Down for... chips (live)"))
        #expect(report.errors == 0)
        #expect(report.inventedWants == 0)
    }

    @Test(.timeLimit(.minutes(2)))
    func proposalSentenceSaysOnlyTheFacts() async throws {
        let now = InterpretationSet.now
        let facts = ProposalFacts(
            skill: SampleSkills.downFor.ref, friendNames: ["Maya", "Jake"], activity: try Keyword("boba"),
            time: try TimeSlot(start: now.addingTimeInterval(8.5 * 3600), end: now.addingTimeInterval(10 * 3600)),
            place: try PlaceName("Boba Guys"), timeZone: InterpretationSet.timeZone
        )
        do {
            let sentence = try await FoundationModelsAgent().proposalText(facts, now: now)
            print("Proposal sentence: \(sentence.value)")
            #expect(sentence.value.contains("Boba Guys"))
        } catch AgentModelError.invalidOutput(let why) {
            // The checks refused it; the app shows the template instead.
            print("Proposal sentence refused: \(why)")
        }
    }
}
