import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

/// Counts the model's readings, and can hold the next one until a test
/// opens it.
actor ReadingCounter {
    private(set) var intents = 0
    private var held: Gate?

    func hold() -> Gate {
        let gate = Gate()
        held = gate
        return gate
    }

    func read() async {
        intents += 1
        if let held {
            self.held = nil
            await held.wait()
        }
    }
}

/// Device test 2 (issue #95): "See who's up for it" was greyed out almost
/// every time, the words were re-read on every edit, and each re-read
/// reset the chips.
@MainActor
@Suite struct ComposeReadingTests {
    static func model(_ counter: ReadingCounter) -> ScriptedSkillModel {
        ScriptedSkillModel(
            onRoute: { _, _ in .downFor },
            onIntent: { text, skill in
                await counter.read()
                let names = text.contains("maya") ? ["Maya"] : []
                return try await ComposerHarness.bobaModel(names: names).onIntent(text, skill)
            }
        )
    }

    @Test func caseAndSpacingAreNotAnEdit() async throws {
        let counter = ReadingCounter()
        let h = try await ComposerHarness(skillModel: Self.model(counter))
        h.model.text = "boba tonight"
        await h.model.understand()
        let generation = h.model.generation
        let constraints = h.model.constraints
        let parts = h.model.chipItems.map(\.part)

        h.model.text = "  Boba   tonight "
        #expect(h.model.generation == generation)
        await h.model.understand()
        #expect(await counter.intents == 1)
        // Not re-read, not reset (the chips show the words as typed).
        #expect(h.model.constraints == constraints)
        #expect(h.model.chipItems.map(\.part) == parts)
    }

    @Test func aReReadKeepsWhatTheOwnerEditedOrRemoved() async throws {
        let counter = ReadingCounter()
        let h = try await ComposerHarness(skillModel: Self.model(counter))
        h.model.text = "boba tonight"
        await h.model.understand()
        #expect(h.model.setWords("movie night", for: .activity))
        #expect(h.model.remove(.issue(.time)))
        h.model.mode = .invite

        h.model.text = "boba tonight with maya"
        await h.model.understand()
        #expect(await counter.intents == 2)
        #expect(h.model.skillChip == "Down for movie night")
        #expect(h.model.constraints.constraints[.time] == nil)
        #expect(h.model.sendMode == .invite)
        // What the owner did not touch follows the new words.
        #expect(h.model.audience == .pick && h.model.picked == [h.maya.id])
    }

    @Test func startStaysOnDuringAReReadAndALateReadingYieldsToTheOwner() async throws {
        let counter = ReadingCounter()
        let h = try await ComposerHarness(skillModel: Self.model(counter))
        h.model.text = "boba tonight"
        await h.model.understand()
        #expect(h.model.canSend)

        let gate = await counter.hold()
        h.model.text = "boba tonight with maya"
        let reading = Task { await h.model.understand() }
        await eventually { h.model.isUnderstanding }
        #expect(h.model.canSend, "the chips already shown can be sent")
        #expect(h.model.sendNote == nil)

        // The owner touches a chip meanwhile: the late reading is dropped.
        #expect(h.model.remove(.issue(.time)))
        await gate.open()
        await reading.value
        #expect(h.model.audience == .allFriends)
        #expect(h.model.constraints.constraints[.time] == nil)
    }

    @Test func theFirstReadingSaysWhyStartIsOff() async throws {
        let counter = ReadingCounter()
        let gate = await counter.hold()
        let h = try await ComposerHarness(skillModel: Self.model(counter))
        h.model.text = "boba tonight"
        let reading = Task { await h.model.understand() }
        await eventually { h.model.isUnderstanding }
        #expect(!h.model.canSend)
        #expect(h.model.sendNote == "Starling is reading this. One moment.")
        await gate.open()
        await reading.value
        #expect(h.model.canSend)
    }

    /// Start is off only with a line under it saying why.
    @Test func startIsNeverOffWithoutAReason() async throws {
        let h = try await ComposerHarness(skillModel: Self.model(ReadingCounter()))
        #expect(!h.model.canSend && h.model.sendNote != nil)
        h.model.text = "boba tonight"
        await h.model.understand()
        #expect(h.model.canSend)
        h.model.audience = .pick
        #expect(!h.model.canSend && h.model.sendNote == "Pick at least one friend to ask.")
        h.model.audience = .everyoneExcept
        for friend in h.friends { h.model.toggle(friend.id) }
        #expect(!h.model.canSend && h.model.sendNote != nil)
    }
}
