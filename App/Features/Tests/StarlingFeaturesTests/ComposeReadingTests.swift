import Foundation
import FindATime
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

    /// A fresh pairing: a friend whose card has not arrived is still asked,
    /// and New says it is waiting to hear from them.
    @Test func aFriendWithoutACardIsAskedAndNewSaysItIsWaiting() async throws {
        let h = try await ComposerHarness(skillModel: Self.model(ReadingCounter()))
        h.model.text = "boba tonight"
        await h.model.understand()
        h.model.audience = .pick
        h.model.picked = [h.leo.id]
        #expect(h.model.participants == [h.leo.id])
        #expect(h.model.canSend)
        #expect(h.model.waitingNote == "Waiting to hear from Leo's Starling. Keep both phones nearby.")
        h.model.picked = [h.maya.id]
        #expect(h.model.waitingNote == nil)
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

/// Device test 2 (issue #95): Find a time's "when" is a range of days,
/// optionally evenings only, not one slot like "tonight after 6 PM".
@MainActor
@Suite struct FindATimeDayRangeTests {
    @Test func theWhenChipTakesARangeOfDaysAndEvenings() async throws {
        let h = try await ComposerHarness(skillModel: ComposerHarness.bobaModel(route: .findATime))
        h.model.text = "find a time for dinner"
        await h.model.understand()
        let chip = try #require(h.model.chipItems.first { $0.part == .issue(.time) })
        guard case .days(let parsed) = chip.editor else { Issue.record("Find a time edits days, got \(chip.editor)"); return }
        #expect(parsed.hours == nil)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Fixtures.utc
        let today = calendar.startOfDay(for: h.clock.now)
        let friday = try #require(calendar.date(byAdding: .day, value: 4, to: today))
        #expect(h.model.setDays(DayRange(from: today, to: friday, hours: .evenings)))
        #expect(h.model.dayRange == DayRange(from: today, to: friday, hours: .evenings))
        let rules = try #require(h.model.constraints.constraints[.time]).map(\.rule)
        #expect(rules == [.within([try TimeSlot(start: today, end: friday.addingTimeInterval(24 * 3600))]), .dailyWindow(from: 17 * 60, to: 22 * 60)])
        let text = try #require(h.model.chipItems.first { $0.part == .issue(.time) }?.text)
        #expect(text == "Today to \(h.model.chipFormatter.dayWord(friday)), Evenings")

        // Back to all day; longer than two weeks is refused.
        #expect(h.model.setDays(DayRange(from: today, to: friday)))
        #expect(h.model.constraints.constraints[.time]?.count == 1)
        let far = try #require(calendar.date(byAdding: .day, value: 20, to: today))
        #expect(!h.model.setDays(DayRange(from: today, to: far)))
        #expect(!h.model.setDays(DayRange(from: friday, to: today)))
    }

    /// Lane C's request 6a: with no days in the words, Find a time asks
    /// about the next week, in a meal's hours for a meal, and the editor
    /// keeps those hours.
    @Test func noDaysInTheWordsMeansNextWeekInTheMealsHours() async throws {
        let model = ScriptedSkillModel(
            onRoute: { _, _ in .findATime },
            onIntent: { _, _ in ParsedIntent(constraints: try ConstraintSet([.activity: [try Constraint(.prefers(liked: [try Keyword("dinner")], avoided: []))]])) }
        )
        let h = try await ComposerHarness(skillModel: model)
        h.model.text = "find a time for dinner"
        await h.model.understand()
        let rules = try #require(h.model.constraints.constraints[.time]).map(\.rule)
        #expect(rules == (try FindATimeDefaults.timeConstraints(activity: try Keyword("dinner"), now: h.clock.now)).map(\.rule))
        #expect(h.model.dayRange.hours == DayRange.Hours(from: 17 * 60, to: 21 * 60))
        let chip = try #require(h.model.chipItems.first { $0.part == .issue(.time) }?.text)
        #expect(plain(chip).hasPrefix("Today to ") && plain(chip).hasSuffix(", Between 5 PM and 9 PM"), "\(plain(chip))")
        #expect(h.model.hoursLabel(.evenings) == "Evenings")
    }
}

/// Device test 2 (issue #95): the Edit sheet holds per-event details only;
/// standing preferences stay in You › Your rules.
@MainActor
@Suite struct EventDetailsTests {
    @Test func downForsDetailsAreWhatWhenWhereAndSpend() async throws {
        let h = try await ComposerHarness()
        h.model.text = "boba tonight"
        await h.model.understand()
        var details = h.model.eventDetails
        #expect(details.fields == [.what, .when, .place, .spendAtMost])
        #expect(details.what == "boba")
        #expect(details.window != nil && details.days == nil)

        details.what = "movie night"
        details.place = "downtown"
        details.spendAtMost = 20
        details.currency = "USD"
        details.window = nil
        #expect(h.model.apply(details) == nil)
        #expect(h.model.skillChip == "Down for movie night")
        #expect(h.model.constraints.constraints[.time] == nil)
        #expect(h.model.chips.contains("Downtown") || h.model.chips.contains("downtown"))
        #expect(h.model.chips.contains("Up to $20.00"))
        // Edited in the sheet, so a re-read keeps them.
        #expect(h.model.ownerSet.isSuperset(of: [.issue(.activity), .issue(.place), .issue(.budget), .issue(.time)]))

        // Something unusable changes nothing.
        let before = h.model.constraints
        details.what = "   "
        #expect(h.model.apply(details) == "Add what you want to do.")
        #expect(h.model.constraints == before)
        details.what = "movie night"
        details.spendAtMost = nil
        #expect(h.model.apply(details) == nil)
        #expect(h.model.constraints.constraints[.budget] == nil)
    }

    @Test func findATimesWhenIsARangeOfDays() async throws {
        let h = try await ComposerHarness(skillModel: ComposerHarness.bobaModel(route: .findATime))
        h.model.text = "find a time for dinner"
        await h.model.understand()
        var details = h.model.eventDetails
        #expect(details.fields == [.what, .when])
        var range = try #require(details.days)
        #expect(details.window == nil)
        range.to = range.from.addingTimeInterval(3 * 24 * 3600)
        range.hours = .evenings
        details.days = range
        #expect(h.model.apply(details) == nil)
        #expect(h.model.dayRange.hours == .evenings)
        range.to = range.from.addingTimeInterval(-24 * 3600)
        details.days = range
        #expect(h.model.apply(details) == "The last day comes before the first.")
    }
}
