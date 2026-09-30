import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

@MainActor
@Suite struct RulesEditorModelTests {
    static func interpreter(_ agent: (any AgentModel)?) -> RulesInterpreter {
        RulesInterpreter(agent: agent, issues: RulesInterpreter.standingIssues, timeZone: TimeZone(identifier: "UTC")!, now: { Fixtures.noon })
    }

    static func agent(returning rules: OwnerRules) -> ScriptedAgentModel {
        ScriptedAgentModel(onInterpret: { _, _ in rules })
    }

    @Test func interpretationOpensAReviewAndDoesNotSave() async throws {
        let store = InMemoryRulesStore()
        let model = RulesEditorModel(interpreter: Self.interpreter(Self.agent(returning: Fixtures.budgetRules)), store: store)
        await model.load()
        #expect(model.phase == .writing)

        model.text = "under $15, never share where I am"
        await model.interpret()

        #expect(model.phase == .reviewing)
        #expect(try model.draft.build() == Fixtures.budgetRules)
        #expect(await store.saved == nil)
    }

    @Test func savingStoresTheEditedRulesNotTheModelOutput() async throws {
        let store = InMemoryRulesStore()
        let model = RulesEditorModel(interpreter: Self.interpreter(Self.agent(returning: Fixtures.budgetRules)), store: store, now: { Fixtures.noon })
        await model.load()
        model.text = "under $15"
        await model.interpret()
        model.draft.items[0].amountMinorUnits = 1200
        model.draft.sharing.removeAll()

        #expect(await model.save())

        let saved = try #require(await store.saved)
        #expect(saved.rules.constraints[.budget] == [try Constraint(.atMost(try MoneyAmount(minorUnits: 1200)))])
        #expect(saved.rules.disclosure.isEmpty)
        #expect(model.phase == .saved)
    }

    @Test func invalidRowsBlockSaving() async throws {
        let store = InMemoryRulesStore()
        let model = RulesEditorModel(interpreter: Self.interpreter(nil), store: store)
        await model.load()
        model.editByHand()
        model.draft.add(.prefers, issue: .activity)

        #expect(await model.save() == false)
        #expect(model.phase == .reviewing)
        #expect(model.notice != nil)
        #expect(await store.saved == nil)
    }

    @Test func flagsInventedRowsAgainstTheOwnersWords() async throws {
        let invented = OwnerRules(constraints: try ConstraintSet([
            .activity: [try Constraint(.prefers(liked: [try Keyword("karaoke")], avoided: []))],
        ]))
        let model = RulesEditorModel(interpreter: Self.interpreter(Self.agent(returning: invented)), store: InMemoryRulesStore())
        await model.load()
        model.text = "free tonight"
        await model.interpret()
        #expect(model.flags.count == 1)
    }

    @Test func newInterpretationAddsToSavedRules() async throws {
        let existing = SavedRules(rules: Fixtures.budgetRules, savedAt: Fixtures.noon)
        let diet = OwnerRules(constraints: try ConstraintSet([.diet: [try Constraint(.mustBe(true))]]))
        let model = RulesEditorModel(interpreter: Self.interpreter(Self.agent(returning: diet)), store: InMemoryRulesStore(existing))
        await model.load()
        #expect(model.phase == .saved)

        model.text = "vegetarian"
        await model.interpret()

        let built = try model.draft.build()
        #expect(built.constraints[.budget] == Fixtures.budgetRules.constraints[.budget])
        #expect(built.constraints[.diet] == diet.constraints[.diet])
        #expect(model.flags.isEmpty, "saved rows are the owner's, so only new rows can be flagged")
    }

    @Test func unavailableModelFallsBackToEditingByHand() async {
        let agent = ScriptedAgentModel(onInterpret: { _, _ in throw AgentModelError.unavailable(reason: "not eligible") })
        let model = RulesEditorModel(interpreter: Self.interpreter(agent), store: InMemoryRulesStore())
        await model.load()
        model.text = "no plans before 10"
        await model.interpret()
        #expect(model.phase == .reviewing)
        #expect(model.draft.items.isEmpty)
        #expect(model.notice != nil)
    }

    @Test func modelFailureKeepsTheOwnersWords() async {
        let agent = ScriptedAgentModel(onInterpret: { _, _ in throw AgentModelError.invalidOutput("junk") })
        let model = RulesEditorModel(interpreter: Self.interpreter(agent), store: InMemoryRulesStore())
        await model.load()
        model.text = "no plans before 10"
        await model.interpret()
        #expect(model.phase == .writing)
        #expect(model.text == "no plans before 10")
        #expect(model.notice != nil)
    }

    @Test func passesTheOwnersWordsAndContextToTheModel() async throws {
        let seen = Recorder<(String, [IssueKey])>()
        let agent = ScriptedAgentModel(onInterpret: { utterance, context in
            await seen.record((utterance.text, context.issues))
            return .empty
        })
        let model = RulesEditorModel(interpreter: Self.interpreter(agent), store: InMemoryRulesStore())
        await model.load()
        model.text = "  no plans before 10 \n"
        await model.interpret()
        let call = try #require(await seen.values.first)
        #expect(call.0 == "no plans before 10")
        #expect(call.1 == RulesInterpreter.standingIssues)
    }

    @Test func emptyTextNeverReachesTheModel() async {
        let calls = Recorder<Int>()
        let agent = ScriptedAgentModel(onInterpret: { _, _ in await calls.record(1); return .empty })
        let model = RulesEditorModel(interpreter: Self.interpreter(agent), store: InMemoryRulesStore())
        await model.load()
        model.text = "   "
        await model.interpret()
        #expect(await calls.values.isEmpty)
        #expect(model.phase == .writing)
    }

    @Test func discardReturnsWithoutSaving() async {
        let store = InMemoryRulesStore()
        let model = RulesEditorModel(interpreter: Self.interpreter(Self.agent(returning: Fixtures.budgetRules)), store: store)
        await model.load()
        model.text = "under $15"
        await model.interpret()
        model.discard()
        #expect(model.phase == .writing)
        #expect(await store.saved == nil)
    }
}
