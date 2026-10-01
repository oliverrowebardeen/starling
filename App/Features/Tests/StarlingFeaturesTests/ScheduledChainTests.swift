import Foundation
import StarlingChaining
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

/// Lane E's after-plan-ends links, applied by the coordinator (P15-E 4.5).
@MainActor
@Suite struct ScheduledChainTests {
    let clock = TestClock()
    let me = PeerID.random()
    let maya = PeerID.random()
    let jake = PeerID.random()
    let down = ScriptedSkillService(descriptor: SampleSkills.downFor)
    let swap = ScriptedSkillService(descriptor: SampleSkills.swapPhotos)
    let swapOn = SkillSettings(flags: SkillFlags(SkillFlags.phase1_5.enabled.union([.swapPhotos])))

    var planner: ChainPlanner { ChainPlanner(registry: SampleSkills.registry, me: me) }

    var cards: [PeerID: AgentCard] {
        let card = try! AgentCard(model: .onDevice, capabilities: [], skills: SampleSkills.all.map(\.ref))
        return [maya: card, jake: card]
    }

    /// A plan ending in an hour, and the Swap photos link the owner opted
    /// into on It's a plan.
    func optedIn() throws -> (parent: Interaction, waiting: Interaction) {
        var parent = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya, jake], createdAt: Timestamp(clock.now))
        let plan = try Plan(origin: parent.conversation, attendees: Attendees([me, maya, jake]), activity: Keyword("boba"),
                            time: TimeSlot(start: clock.now, end: clock.now.addingTimeInterval(3600)))
        let proposal = SkillProposal(revision: 1, participants: [me, maya, jake], terms: try Terms([.activity: .keywords([try Keyword("boba")])]), plan: plan)
        for event: InteractionEvent in [.started, .proposalReady(proposal), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try parent.apply(event, at: Timestamp(clock.now))
        }
        parent.record(.plan(plan))
        let row = try #require(planner.suggestions(after: parent.id, in: [parent], settings: swapOn, cards: cards).first { $0.id == .swapPhotos })
        let tap = OwnerTap(at: Timestamp(clock.now.addingTimeInterval(60)))
        let waiting = try planner.optIn(row, in: [parent], settings: swapOn, cards: cards, tap: tap, consent: row.consent(approvedAt: tap.at))
        return (parent, waiting)
    }

    func coordinator(_ items: [Interaction]) async -> LifecycleCoordinator {
        let lifecycle = LifecycleCoordinator(registry: SampleSkills.registry, services: [down, swap], store: InMemoryInteractionStore(items), now: clock.closure)
        await lifecycle.start()
        return lifecycle
    }

    func due(_ lifecycle: LifecycleCoordinator, settings: SkillSettings) -> [ScheduledChain] {
        PlanEndSchedule(planner: planner).check(at: clock.now, interactions: lifecycle.interactions, settings: settings, cards: cards)
    }

    @Test func aDueLinkStartsOnceWithThePlanAsItsInput() async throws {
        let (parent, waiting) = try optedIn()
        let lifecycle = await coordinator([parent, waiting])
        clock.advance(3700)
        let results = due(lifecycle, settings: swapOn)
        #expect(results.count == 1)

        for result in results { await lifecycle.applyScheduled(result, rules: .empty, expiresAt: Timestamp(clock.now.addingTimeInterval(3600))) }
        let started = try #require(lifecycle.interaction(waiting.id))
        #expect(started.state != .drafting)
        let request = try #require(await swap.started.first)
        #expect(request.interaction == waiting.id)
        #expect(request.chainedFrom == parent.conversation)
        #expect(Set(request.participants) == [maya, jake])

        // The same hand-over again is stale: the link no longer waits.
        for result in results { await lifecycle.applyScheduled(result, rules: .empty, expiresAt: Timestamp(clock.now.addingTimeInterval(3600))) }
        #expect(await swap.started.count == 1)
    }

    @Test func aLinkThatCanNoLongerRunEndsWithItsReasonAndSendsNothing() async throws {
        let (parent, waiting) = try optedIn()
        let lifecycle = await coordinator([parent, waiting])
        clock.advance(3700)
        // Swap photos was turned off before the plan ended.
        let results = due(lifecycle, settings: SkillSettings(flags: .phase1_5))
        #expect(results == [.cancel(waiting, .withdrawn)])

        for result in results { await lifecycle.applyScheduled(result, rules: .empty, expiresAt: Timestamp(clock.now)) }
        #expect(lifecycle.interaction(waiting.id)?.state == .ended(.withdrawn))
        #expect(await swap.started.isEmpty)
    }

    /// P15-E 4.5: someone who left the plan after the opt-in is left out of
    /// the started link and its request.
    @Test func aStartedLinkKeepsOnlyThePlansPeopleAsTheyStandNow() async throws {
        var (parent, waiting) = try optedIn()
        let narrower = try Plan(origin: parent.conversation, attendees: Attendees([me, maya]), activity: Keyword("boba"),
                                time: TimeSlot(start: clock.now, end: clock.now.addingTimeInterval(3600)))
        parent.record(.plan(narrower))
        let lifecycle = await coordinator([parent, waiting])
        clock.advance(3700)
        for result in due(lifecycle, settings: swapOn) {
            await lifecycle.applyScheduled(result, rules: .empty, expiresAt: Timestamp(clock.now.addingTimeInterval(3600)))
        }
        #expect(lifecycle.interaction(waiting.id)?.participants == [maya])
        #expect(await swap.started.first?.participants == [maya])
    }

    @Test func nothingStartsBeforeThePlanEnds() async throws {
        let (parent, waiting) = try optedIn()
        let lifecycle = await coordinator([parent, waiting])
        #expect(due(lifecycle, settings: swapOn).isEmpty)
        #expect(lifecycle.interaction(waiting.id)?.state == .drafting)
    }
}
