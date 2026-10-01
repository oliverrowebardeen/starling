import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

@MainActor
@Suite struct DownStatusTests {
    @MainActor
    struct Harness {
        let service = ScriptedDownService()
        let maya = Fixtures.peer("Maya")
        let model: DownModel

        init(noMatchHold: Duration = .milliseconds(30)) {
            model = DownModel(
                service: service,
                interpreter: RulesInterpreter(agent: nil, issues: RulesInterpreter.intentIssues),
                rules: InMemoryRulesStore(),
                peers: InMemoryPairedPeerStore([maya]),
                notifier: RecordingNotifier(),
                noMatchHold: noMatchHold
            )
            model.listen()
        }

        func goDown() async {
            await model.editByHand()
            await model.goDown()
        }
    }

    @Test func idleUntilAnIntentIsOut() async {
        let h = Harness()
        #expect(h.model.status == .idle)
        await h.model.editByHand()
        #expect(h.model.status == .idle, "reviewing is not an intent")
        await h.model.goDown()
        #expect(h.model.status == .searching)
    }

    @Test func checkingKeepsSearchingAndAMatchShowsMatch() async {
        let h = Harness()
        await h.goDown()
        h.service.emit(.checking(friends: 2))
        await eventually { h.model.active?.checkingFriends == 2 }
        #expect(h.model.status == .searching)

        h.service.emit(.matched(DownMatch(peer: h.maya.id, terms: .empty, bothDown: true)))
        await eventually { h.model.status == .match }
        #expect(h.model.status == .match)

        h.service.emit(.checking(friends: 2))
        await eventually { h.model.active?.checkingFriends == 2 }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.model.status == .match, "a later check does not undo the match")
    }

    @Test func endingWithoutAMatchShowsNoMatchThenIdle() async {
        let h = Harness()
        await h.goDown()
        h.service.emit(.ended(.expired))
        await eventually { h.model.status == .noMatch }
        #expect(h.model.status == .noMatch)
        await eventually { h.model.status == .idle }
        #expect(h.model.status == .idle)
    }

    @Test func endingAfterAMatchGoesStraightToIdle() async {
        let h = Harness(noMatchHold: .seconds(10))
        await h.goDown()
        h.service.emit(.matched(DownMatch(peer: h.maya.id, terms: .empty, bothDown: false)))
        await eventually { h.model.status == .match }
        h.service.emit(.ended(.expired))
        await eventually { h.model.phase == .composing }
        #expect(h.model.status == .idle)
    }

    @Test func withdrawingIsIdleNotNoMatch() async {
        let h = Harness(noMatchHold: .seconds(10))
        await h.goDown()
        await h.model.withdraw()
        #expect(h.model.status == .idle)
    }

    @Test func aNewIntentCancelsThePendingIdle() async {
        let h = Harness(noMatchHold: .milliseconds(50))
        await h.goDown()
        h.service.emit(.ended(.failed))
        await eventually { h.model.status == .noMatch }
        await h.goDown()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.model.status == .searching)
    }
}
