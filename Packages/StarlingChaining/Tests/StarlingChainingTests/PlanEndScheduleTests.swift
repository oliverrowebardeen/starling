import Foundation
import StarlingChaining
import StarlingCore
import StarlingFakes
import Synchronization
import Testing

/// A clock tests move by hand; `sleep` moves it instead of waiting.
final class TestClock: Sendable {
    private let time: Mutex<Date>
    private let naps = Mutex<[Duration]>([])

    init(_ start: Date) { time = Mutex(start) }

    var now: Date { time.withLock { $0 } }
    var slept: [Duration] { naps.withLock { $0 } }

    func advance(to date: Date) { time.withLock { $0 = date } }

    func sleep(_ duration: Duration) {
        naps.withLock { $0.append(duration) }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        time.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

@Suite struct PlanEndScheduleTests {
    let planner = ChainPlanner(registry: SampleSkills.registry, me: Fixtures.me)
    let swapOn = SkillSettings(flags: Fixtures.flagsWithSwapPhotos)
    var schedule: PlanEndSchedule { PlanEndSchedule(planner: planner) }
    let afterTheEnd = Fixtures.tonight.end.addingTimeInterval(60)

    /// A planned Down for… and the Swap photos link the owner opted into at
    /// minute 6, on It's a plan.
    func optedIn(settings: SkillSettings? = nil) throws -> (Interaction, Interaction) {
        let plan = try Fixtures.plannedDownFor()
        let row = try #require(planner.suggestions(after: plan.id, in: [plan], settings: swapOn, cards: Fixtures.cards()).first { $0.id == .swapPhotos })
        let tap = OwnerTap(at: Fixtures.at(minutes: 6))
        let waiting = try planner.optIn(row, in: [plan], settings: swapOn, cards: Fixtures.cards(), tap: tap, consent: row.consent(approvedAt: tap.at))
        return (plan, waiting)
    }

    @Test func theHookFiresWhenThePlanEndsWithTheOptIn() throws {
        let (plan, waiting) = try optedIn()
        #expect(schedule.check(at: Fixtures.date(minutes: 209), interactions: [plan, waiting], settings: swapOn, cards: Fixtures.cards()).isEmpty)
        let results = schedule.check(at: Fixtures.tonight.end, interactions: [plan, waiting], settings: swapOn, cards: Fixtures.cards())
        guard case .start(let due) = try #require(results.first), results.count == 1 else {
            Issue.record("expected one start, got \(results)")
            return
        }
        #expect(due.link.id == waiting.id)
        #expect(due.plan == plan.plan)
        let request = due.request(rules: .empty, expiresAt: Fixtures.at(minutes: 24 * 60))
        #expect(request.interaction == waiting.id)
        #expect(request.chainedFrom == plan.conversation)
        #expect(request.inputs == [.plan(try #require(plan.plan))])
        #expect(request.participants == [Fixtures.maya, Fixtures.jake])
        // The coordinator applies .started; the link then no longer waits.
        var started = waiting
        try started.apply(.started, at: Timestamp(Fixtures.tonight.end))
        #expect(schedule.check(at: afterTheEnd, interactions: [plan, started], settings: swapOn, cards: Fixtures.cards()).isEmpty)
    }

    @Test func withoutAnOptInNothingFires() throws {
        let plan = try Fixtures.plannedDownFor()
        #expect(schedule.check(at: afterTheEnd, interactions: [plan], settings: swapOn, cards: Fixtures.cards()).isEmpty)
        #expect(schedule.nextEnd(after: Fixtures.now, interactions: [plan]) == nil)
    }

    @Test func onlyAnOptInRecordedOnAPlanCounts() throws {
        let (plan, _) = try optedIn()
        // A link that claims an opt-in from before the parent was a plan.
        let early = Interaction(skill: SampleSkills.swapPhotos.ref, role: .initiator, participants: [Fixtures.maya, Fixtures.jake],
                                createdAt: Fixtures.at(minutes: 2),
                                chain: ChainLink(parent: plan.id, parentConversation: plan.conversation, consumed: [.plan], trigger: .afterPlanEnds,
                                                 optedInAt: Fixtures.at(minutes: 2)))
        #expect(schedule.check(at: afterTheEnd, interactions: [plan, early], settings: swapOn, cards: Fixtures.cards()) == [.cancel(early, .withdrawn)])
        // A link naming the parent's ID but another conversation.
        let mismatched = Interaction(skill: SampleSkills.swapPhotos.ref, role: .initiator, participants: [Fixtures.maya], createdAt: Fixtures.at(minutes: 6),
                                     chain: ChainLink(parent: plan.id, parentConversation: ConversationID(), consumed: [.plan], trigger: .afterPlanEnds,
                                                      optedInAt: Fixtures.at(minutes: 6)))
        #expect(schedule.check(at: afterTheEnd, interactions: [plan, mismatched], settings: swapOn, cards: Fixtures.cards()) == [.cancel(mismatched, .withdrawn)])
        // An invitee interaction never waits for a plan's end, whatever it holds.
        let invitee = Interaction(skill: SampleSkills.swapPhotos.ref, role: .invitee, participants: [Fixtures.maya], createdAt: Fixtures.at(minutes: 6),
                                  chain: ChainLink(parent: plan.id, parentConversation: plan.conversation, consumed: [.plan], trigger: .afterPlanEnds,
                                                   optedInAt: Fixtures.at(minutes: 6)))
        #expect(!ChainPlanner.isWaitingForPlanEnd(invitee))
        #expect(schedule.check(at: afterTheEnd, interactions: [plan, invitee], settings: swapOn, cards: Fixtures.cards()).isEmpty)
    }

    @Test func aCalledOffPlanCancelsTheLink() throws {
        var (plan, waiting) = try optedIn()
        try plan.apply(.withdrawn, at: Fixtures.at(minutes: 30))
        let results = schedule.check(at: Fixtures.date(minutes: 31), interactions: [plan, waiting], settings: swapOn, cards: Fixtures.cards())
        #expect(results == [.cancel(waiting, .withdrawn)])
        // A missing parent cancels too.
        #expect(schedule.check(at: Fixtures.date(minutes: 31), interactions: [waiting], settings: swapOn, cards: Fixtures.cards()) == [.cancel(waiting, .withdrawn)])
    }

    @Test func everythingIsCheckedAgainWhenThePlanEnds() throws {
        let (plan, waiting) = try optedIn()
        let all = [plan, waiting]
        // Flagged off again in this build, or switched off by the owner.
        #expect(schedule.check(at: afterTheEnd, interactions: all, settings: SkillSettings(flags: .phase1_5), cards: Fixtures.cards()) == [.cancel(waiting, .withdrawn)])
        #expect(schedule.check(at: afterTheEnd, interactions: all, settings: SkillSettings(flags: Fixtures.flagsWithSwapPhotos, turnedOff: [.swapPhotos]),
                               cards: Fixtures.cards()) == [.cancel(waiting, .withdrawn)])
        // Photos set to Never since Confirm.
        let never = SkillSettings(flags: Fixtures.flagsWithSwapPhotos, privacy: try PrivacySettings([.photos: .never]))
        #expect(schedule.check(at: afterTheEnd, interactions: all, settings: never, cards: Fixtures.cards()) == [.cancel(waiting, .blockedByPrivacy)])
        // Maya no longer runs Swap photos.
        var cards = Fixtures.cards()
        cards[Fixtures.maya] = Fixtures.card([SampleSkills.downFor])
        #expect(schedule.check(at: afterTheEnd, interactions: all, settings: swapOn, cards: cards) == [.cancel(waiting, .unsupported)])
        // Every cancel is an event the waiting interaction accepts.
        for event in [InteractionEvent.withdrawn, .unsupported, .blockedByPrivacy] {
            var copy = waiting
            try copy.apply(event, at: Timestamp(afterTheEnd))
            #expect(copy.state.isFinal)
        }
    }

    @Test func theNextEndIsTheEarliestStillToCome() throws {
        let (plan, waiting) = try optedIn()
        #expect(schedule.nextEnd(after: Fixtures.now, interactions: [plan, waiting]) == Fixtures.tonight.end)
        #expect(schedule.nextEnd(after: afterTheEnd, interactions: [plan, waiting]) == nil)
    }

    @Test func theSchedulerHandsEachLinkOverOnce() async throws {
        let (plan, waiting) = try optedIn()
        let clock = TestClock(afterTheEnd)
        let swapOn = self.swapOn
        let scheduler = PlanEndScheduler(schedule: schedule, store: InMemoryInteractionStore([plan, waiting]),
                                         settings: { swapOn }, cards: { Fixtures.cards() }, now: { clock.now })
        let first = try await scheduler.due()
        #expect(first.count == 1)
        #expect(try await scheduler.due().isEmpty)
    }

    @Test func theSchedulerSleepsUntilThePlanEndsThenStartsTheLink() async throws {
        let (plan, waiting) = try optedIn()
        let clock = TestClock(Fixtures.now)
        let handed = Mutex<[ScheduledChain]>([])
        let swapOn = self.swapOn
        let scheduler = PlanEndScheduler(
            schedule: schedule, store: InMemoryInteractionStore([plan, waiting]),
            settings: { swapOn }, cards: { Fixtures.cards() }, now: { clock.now },
            sleep: { duration in
                if !handed.withLock({ $0.isEmpty }) { throw CancellationError() }
                clock.sleep(duration)
            },
            maxNap: .seconds(4 * 3600)
        )
        await scheduler.run { results in handed.withLock { $0.append(contentsOf: results) } }
        let results = handed.withLock { $0 }
        guard case .start(let due) = try #require(results.first) else {
            Issue.record("expected a start, got \(results)")
            return
        }
        #expect(due.link.id == waiting.id)
        // One nap, straight to the plan's end, then the hand-over.
        #expect(clock.slept == [.seconds(210 * 60)])
        #expect(clock.now == Fixtures.tonight.end)
    }

    @Test func anOptOutWhileSettingsLoadIsNotStarted() async throws {
        let (plan, waiting) = try optedIn()
        let store = InMemoryInteractionStore([plan, waiting])
        let gate = Gate()
        let swapOn = self.swapOn
        let afterTheEnd = self.afterTheEnd
        let scheduler = PlanEndScheduler(schedule: schedule, store: store, settings: { await gate.pass(); return swapOn },
                                         cards: { Fixtures.cards() }, now: { afterTheEnd })
        let checking = Task { try await scheduler.due() }
        await gate.arrived()
        // The owner switches "Swap photos after" off while settings load.
        try await store.remove(try planner.optOut(waiting, tap: OwnerTap(at: Timestamp(afterTheEnd))))
        await gate.open()
        #expect(try await checking.value.isEmpty)
    }

    @Test func theCoordinatorClaimsALinkRightBeforeStartingIt() async throws {
        let (plan, waiting) = try optedIn()
        let store = InMemoryInteractionStore([plan, waiting])
        let swapOn = self.swapOn
        let scheduler = PlanEndScheduler(schedule: schedule, store: store, settings: { swapOn }, cards: { Fixtures.cards() },
                                         now: { [afterTheEnd] in afterTheEnd })
        let handed = try #require(try await scheduler.due().first)
        #expect(try await scheduler.claim(handed) == waiting)
        #expect(handed.isCurrent(waiting))

        // Opted out after the hand-over: the claim refuses it.
        try await store.remove(waiting.id)
        #expect(try await scheduler.claim(handed) == nil)
        #expect(!handed.isCurrent(nil))

        // Already started (a second hand-over, or another path): refused too.
        var started = waiting
        try started.apply(.started, at: Timestamp(afterTheEnd))
        try await store.save(started)
        #expect(try await scheduler.claim(handed) == nil)
        #expect(!handed.isCurrent(started))

        // A different link that happens to wait under the same plan is not this one.
        let other = Interaction(skill: waiting.skill, role: .initiator, participants: waiting.participants, createdAt: waiting.createdAt, chain: waiting.chain)
        #expect(!handed.isCurrent(other))
    }
}
