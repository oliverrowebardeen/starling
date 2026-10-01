import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

actor CountingPrompter: LocalNetworkPrompter {
    private(set) var prompts = 0
    func prompt() async { prompts += 1 }
}

@MainActor
@Suite struct OnboardingModelTests {
    @Test func walksEveryStepAndAsksForEachPermissionOnce() async {
        let prompter = CountingPrompter()
        let notifier = RecordingNotifier(allow: false)
        let model = OnboardingModel(localNetwork: prompter, notifier: notifier)

        #expect(model.step == .welcome)
        await model.next()
        #expect(model.step == .localNetwork)
        #expect(await prompter.prompts == 0, "the alert fires only after the explanation")
        await model.next()
        #expect(model.step == .notifications)
        #expect(await prompter.prompts == 1)
        await model.next()
        #expect(model.step == .rules)
        #expect(model.notificationsAllowed == false)
        #expect(await notifier.authorizationRequests == 1)
        await model.next()
        #expect(model.isFinished)
    }

    @Test func notificationsCanBeSkippedButLocalNetworkCannot() async {
        let notifier = RecordingNotifier()
        let model = OnboardingModel(localNetwork: CountingPrompter(), notifier: notifier)
        await model.next()
        model.skip()
        #expect(model.step == .localNetwork)
        await model.next()
        model.skip()
        #expect(model.step == .rules)
        #expect(await notifier.authorizationRequests == 0)
        model.skip()
        #expect(model.isFinished)
    }

    /// Codex review of PR #42 (finding 3): the radios' Bonjour work raises
    /// the Local Network alert, so they start only after its explanation.
    @Test func linksStartOnlyAfterTheLocalNetworkStep() async {
        let prompter = CountingPrompter()
        let started = Recorder<Int>()
        let model = OnboardingModel(localNetwork: prompter, notifier: RecordingNotifier(), startLinks: {
            await started.record(await prompter.prompts)
        })
        await model.next()
        #expect(model.step == .localNetwork)
        #expect(await started.values.isEmpty, "not while the welcome screen shows")
        await model.next()
        #expect(await started.values == [1], "after the explanation and the deliberate prompt")
        await model.next()
        await model.next()
        #expect(await started.values == [1])
    }
}
