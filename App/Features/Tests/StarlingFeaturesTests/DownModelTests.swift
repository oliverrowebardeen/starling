import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

actor RecordingNotifier: MatchNotifier {
    private(set) var posted: [MatchNotice] = []
    private(set) var authorizationRequests = 0
    let allow: Bool

    init(allow: Bool = true) { self.allow = allow }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return allow
    }

    func post(_ notice: MatchNotice) async { posted.append(notice) }
}

@MainActor
final class Counter {
    var count = 0
}

@MainActor
@Suite struct DownModelTests {
    static let tonight = try! TimeSlot(start: Fixtures.noon.addingTimeInterval(7 * 3600), end: Fixtures.noon.addingTimeInterval(11 * 3600))
    static let intentRules = OwnerRules(constraints: try! ConstraintSet([
        .time: [try! Constraint(.within([tonight]))],
        .activity: [try! Constraint(.prefers(liked: [try! Keyword("food")], avoided: []))],
    ]))

    struct Harness {
        let service = ScriptedDownService()
        let notifier = RecordingNotifier()
        let maya = Fixtures.peer("Maya")
        let peers: InMemoryPairedPeerStore
        let rules: InMemoryRulesStore
        let model: DownModel
        let intentChanges = Counter()

        @MainActor
        init(standing: OwnerRules? = nil, interpretation: OwnerRules = DownModelTests.intentRules) {
            peers = InMemoryPairedPeerStore([maya])
            rules = InMemoryRulesStore(standing.map { SavedRules(rules: $0, savedAt: Fixtures.noon) })
            let agent = ScriptedAgentModel(onInterpret: { _, _ in interpretation })
            model = DownModel(
                service: service,
                interpreter: RulesInterpreter(agent: agent, issues: RulesInterpreter.intentIssues, timeZone: Fixtures.utc, now: { Fixtures.noon }),
                rules: rules,
                peers: peers,
                notifier: notifier,
                formatter: ValueFormatter(timeZone: Fixtures.utc, locale: Locale(identifier: "en_US")),
                timeZone: Fixtures.utc,
                now: { Fixtures.noon },
                intentChanged: { [intentChanges] in intentChanges.count += 1 }
            )
            model.listen()
        }

        @MainActor
        func goDown(_ level: DownLevel = .down, duration: DownDuration = .threeHours) async {
            model.text = "free tonight, want food"
            await model.interpret()
            model.level = level
            model.duration = duration
            await model.goDown()
        }
    }

    @Test func publishesTheReviewedIntentMergedWithStandingRules() async throws {
        let standing = OwnerRules(
            constraints: try ConstraintSet([.budget: [try Constraint(.atMost(try MoneyAmount(minorUnits: 1500)))]]),
            disclosure: [DisclosureRule(issue: .place, action: .never)]
        )
        let h = Harness(standing: standing)
        await h.goDown(.maybe, duration: .oneHour)

        let intent = try #require(await h.service.intents.first)
        #expect(intent.level == .maybe)
        #expect(intent.expiresAt == Timestamp(Fixtures.noon.addingTimeInterval(3600)))
        #expect(intent.rules == (try RulesMerge.intent(Self.intentRules, standing: standing)))
        #expect(h.model.phase == .active)
        #expect(h.model.active?.level == .maybe)
    }

    @Test func goingDownRequiresTheReviewStep() async {
        let h = Harness()
        h.model.text = "free tonight"
        await h.model.goDown()
        #expect(await h.service.intents.isEmpty)
        #expect(h.model.phase == .composing)
    }

    @Test func ownerEditsReachTheService() async throws {
        let h = Harness()
        h.model.text = "free tonight, want food"
        await h.model.interpret()
        #expect(h.model.phase == .reviewing)
        h.model.draft.items.removeAll { $0.kind == .prefers }
        await h.model.goDown()
        let intent = try #require(await h.service.intents.first)
        #expect(intent.rules.constraints[.activity].isEmpty)
    }

    @Test func notifiesOnlyOnAMatch() async throws {
        let h = Harness()
        await h.goDown()

        h.service.emit(.checking(friends: 3))
        await eventually { h.model.active?.checkingFriends == 3 }
        #expect(await h.notifier.posted.isEmpty)

        let terms = try Terms([.activity: .keywords([try Keyword("boba run")])])
        h.service.emit(.matched(DownMatch(peer: h.maya.id, terms: terms, bothDown: true)))
        await eventually { !h.model.matches.isEmpty }

        h.service.emit(.ended(.expired))
        await eventually { h.model.phase == .composing }

        let posted = await h.notifier.posted
        #expect(posted.count == 1)
        #expect(posted.first?.title == "You and Maya are both down")
        #expect(posted.first?.body == "Activity: boba run")
        #expect(h.model.matches.first?.friendName == "Maya")
    }

    @Test func aMaybeMatchSaysInterestedNotDown() async throws {
        let h = Harness()
        await h.goDown(.maybe)
        h.service.emit(.matched(DownMatch(peer: h.maya.id, terms: .empty, bothDown: false)))
        await eventually { !h.model.matches.isEmpty }
        let notice = try #require(await h.notifier.posted.first)
        #expect(notice.title == "You and Maya are both interested")
    }

    @Test func aRepeatMatchReplacesTheRowAndTheNotification() async throws {
        let h = Harness()
        await h.goDown()
        h.service.emit(.matched(DownMatch(peer: h.maya.id, terms: .empty, bothDown: true)))
        h.service.emit(.matched(DownMatch(peer: h.maya.id, terms: try Terms([.budget: .amount(try MoneyAmount(minorUnits: 900))]), bothDown: true)))
        await eventually { h.model.matches.first?.lines.isEmpty == false }
        #expect(h.model.matches.count == 1)
        let ids = await h.notifier.posted.map(\.id)
        #expect(ids.count == 2)
        #expect(Set(ids).count == 1)
    }

    @Test func withdrawClearsTheIntent() async {
        let h = Harness()
        await h.goDown()
        await h.model.withdraw()
        #expect(await h.service.cleared == 1)
        #expect(h.model.phase == .composing)
        #expect(h.model.active == nil)
    }

    @Test func failureEndsQuietlyWithAnHonestNote() async {
        let h = Harness()
        await h.goDown()
        h.service.emit(.ended(.failed))
        await eventually { h.model.phase == .composing }
        #expect(h.model.notice?.contains("Nobody was notified") == true)
        #expect(await h.notifier.posted.isEmpty)
    }

    @Test func mergeOverLimitsKeepsTheReviewOpen() async throws {
        let many = try (0..<ConstraintSet.maxConstraintsPerIssue).map { _ in try Constraint(.mustBe(true)) }
        let standing = OwnerRules(constraints: try ConstraintSet([.time: many]))
        let h = Harness(standing: standing)
        await h.goDown()
        #expect(h.model.phase == .reviewing)
        #expect(h.model.notice != nil)
        #expect(await h.service.intents.isEmpty)
    }

    @Test func reportsEveryIntentChange() async {
        let h = Harness()
        await h.goDown()
        #expect(h.intentChanges.count == 1)
        await h.model.withdraw()
        #expect(h.intentChanges.count == 2)
        await h.goDown()
        h.service.emit(.ended(.expired))
        await eventually { h.model.phase == .composing }
        #expect(h.intentChanges.count == 4)
    }

    @Test func untilMidnightEndsAtTheNextLocalMidnight() {
        let expiry = DownDuration.tonight.expiry(from: Fixtures.noon, timeZone: Fixtures.utc)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Fixtures.utc
        #expect(calendar.dateComponents([.hour, .minute], from: expiry) == DateComponents(hour: 0, minute: 0))
        #expect(expiry > Fixtures.noon)
        #expect(expiry.timeIntervalSince(Fixtures.noon) <= 24 * 3600)
    }
}
