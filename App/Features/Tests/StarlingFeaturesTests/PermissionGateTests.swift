import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

/// A permission whose system alert answers with `answer`.
actor FakeAccess: PermissionAccess {
    nonisolated let permission: SystemPermission
    private var current: PermissionStatus
    private let answer: PermissionStatus
    private(set) var requests = 0

    init(_ permission: SystemPermission, status: PermissionStatus = .notDetermined, answer: PermissionStatus = .granted) {
        self.permission = permission
        current = status
        self.answer = answer
    }

    func status() async -> PermissionStatus { current }
    func request() async -> PermissionStatus {
        requests += 1
        current = answer
        return answer
    }
}

@MainActor
@Suite struct PermissionGateTests {
    let skill = SampleSkills.findATime

    func settings() async -> SettingsModel {
        let model = SettingsModel(store: InMemoryOwnerSettingsStore(), flags: .phase1_5)
        await model.load()
        return model
    }

    /// The system alert appears only after the owner taps Continue on
    /// Starling's sheet (ADR 0013 decision 3).
    @Test func theSheetComesFirstAndContinueLeadsToTheSystemAlert() async throws {
        let access = FakeAccess(.calendarFullAccess)
        let gate = PermissionGate(access: [access])
        let settings = await settings()
        let outcome = Task { await gate.prepare(.calendarFullAccess, for: skill, friends: ["Priya"], settings: settings) }
        await eventually { gate.pending != nil }
        #expect(gate.pending?.title == "Find a time works best with your calendar")
        #expect(await access.requests == 0)

        gate.proceed()
        #expect(await outcome.value == .granted)
        #expect(await access.requests == 1)
        #expect(gate.pending == nil)
        #expect(settings.settings.permissionsExplained == [.calendarFullAccess])
    }

    @Test func denialFallsBackToJustAskMeAndIsRemembered() async throws {
        let access = FakeAccess(.calendarFullAccess, answer: .denied)
        let gate = PermissionGate(access: [access])
        let settings = await settings()
        let outcome = Task { await gate.prepare(.calendarFullAccess, for: skill, friends: [], settings: settings) }
        await eventually { gate.pending != nil }
        gate.proceed()
        #expect(await outcome.value == .askInstead(fallback: "No problem, your agent will ask you instead."))
        #expect(settings.asksInstead(.findATime))

        // Next time: no sheet, no alert.
        #expect(await gate.prepare(.calendarFullAccess, for: skill, friends: [], settings: settings) == .askInstead(fallback: nil))
        #expect(await access.requests == 1)
    }

    @Test func aSettledPermissionShowsNothing() async throws {
        let settings = await settings()
        let granted = PermissionGate(access: [FakeAccess(.calendarFullAccess, status: .granted)])
        #expect(await granted.prepare(.calendarFullAccess, for: skill, friends: [], settings: settings) == .granted)
        let denied = PermissionGate(access: [FakeAccess(.calendarFullAccess, status: .denied)])
        #expect(await denied.prepare(.calendarFullAccess, for: skill, friends: [], settings: settings) == .askInstead(fallback: nil))
        let limited = PermissionGate(access: [FakeAccess(.photoLibrary, status: .limited)])
        #expect(await limited.prepare(.photoLibrary, for: SampleSkills.swapPhotos, friends: [], settings: settings) == .limited)
        #expect(granted.pending == nil && denied.pending == nil)
    }

    @Test func withoutAnAccessAPIThePermissionIsUnavailable() async throws {
        let gate = PermissionGate(access: [])
        #expect(await gate.prepare(.locationWhenInUse, for: SampleSkills.pickAPlace, friends: [], settings: await settings()) == .unavailable)
    }

    @Test func choosingJustAskMeInYouSkipsThePermission() async throws {
        let access = FakeAccess(.calendarFullAccess)
        let gate = PermissionGate(access: [access])
        let settings = await settings()
        await settings.setAskInstead(.findATime, true)
        #expect(await gate.prepare(.calendarFullAccess, for: skill, friends: [], settings: settings) == .askInstead(fallback: nil))
        #expect(await access.requests == 0)
    }

    @Test func theSheetKeepsTheMockupsThreeRows() {
        let sheet = PermissionExplanation.make(.calendarFullAccess, skill: skill, friends: ["Priya"])
        #expect(sheet.rows == [
            DisplayLine(title: "Your agent reads", detail: "When you're busy or free"),
            DisplayLine(title: "Never leaves your phone", detail: "Event names, places, people"),
            DisplayLine(title: "Priya sees", detail: "Only a few times you're free"),
        ])
        // ADR 0013 amendment 6: "both free" is true only when answering.
        let answering = PermissionExplanation.make(.calendarFullAccess, skill: skill, friends: ["Priya"], role: .invitee)
        #expect(answering.rows[2] == DisplayLine(title: "Priya sees", detail: "Only times you're both free"))
        #expect(sheet.body.contains("Priya's agent never has to ask you"))
        #expect(PermissionExplanation.make(.calendarFullAccess, skill: skill, friends: ["Maya", "Jake"]).rows[2].title == "Maya and Jake see")
        #expect(PermissionExplanation.continueLabel == "Continue")
        for permission in SystemPermission.allCases {
            let text = PermissionExplanation.make(permission, skill: skill, friends: ["A", "B", "C"])
            #expect(!(text.title + text.body + text.fallback + text.rows.map { $0.title + ($0.detail ?? "") }.joined()).contains("\u{2014}"))
        }
    }
}
