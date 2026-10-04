import Foundation
import StarlingChangePlan
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

/// Lane E's Change the plan in the app (ADR 0022, ADR 0243, P15-E requests
/// 10 to 14).
@MainActor
@Suite struct ChangePlanWiringTests {
    let clock = TestClock()
    let maya = PeerID.random()
    let down = ScriptedSkillService(descriptor: SampleSkills.downFor)
    let change = ScriptedSkillService(descriptor: ChangePlan.descriptor)
    let time = ScriptedSkillService(descriptor: SampleSkills.findATime)

    func planned() throws -> Interaction {
        var item = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(clock.now))
        let start = clock.now.addingTimeInterval(3600)
        let plan = try Plan(origin: item.conversation, attendees: Attendees([PeerID.random(), maya]), activity: Keyword("boba"),
                            time: TimeSlot(start: start, end: start.addingTimeInterval(3600)))
        let proposal = SkillProposal(revision: 1, participants: plan.attendees.peers, terms: try Terms([.activity: .keywords([try Keyword("boba")])]), plan: plan)
        for event: InteractionEvent in [.started, .proposalReady(proposal), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try item.apply(event, at: Timestamp(clock.now))
        }
        item.record(.plan(plan))
        return item
    }

    func coordinator(_ items: [Interaction]) async -> LifecycleCoordinator {
        let registry = try! SkillRegistry(SampleSkills.registry.descriptors + [ChangePlan.descriptor])
        let lifecycle = LifecycleCoordinator(registry: registry, services: [down, time, change], store: InMemoryInteractionStore(items), now: clock.closure)
        await lifecycle.start()
        return lifecycle
    }

    /// P15-E request 12: the service updates the plan where it lives, the
    /// interaction of the skill that made it, and nothing else may.
    @Test func changePlanUpdatesThePlanItsOwnInteractionHolds() async throws {
        let plan = try planned()
        let lifecycle = await coordinator([plan])
        let current = try #require(plan.plan)
        let later = try current.updating(activity: .some(try Keyword("dinner")))

        // Another skill can't, nor an older or another plan's revision.
        await lifecycle.handle(.produced(plan.id, .plan(later)), from: SampleSkills.findATime)
        #expect(lifecycle.interaction(plan.id)?.plan == current)
        let otherOrigin = try Plan(origin: ConversationID(), attendees: current.attendees, activity: Keyword("dinner"), time: current.time, revision: 1)
        await lifecycle.handle(.produced(plan.id, .plan(otherOrigin)), from: ChangePlan.descriptor)
        #expect(lifecycle.interaction(plan.id)?.plan == current)

        await lifecycle.handle(.produced(plan.id, .plan(later)), from: ChangePlan.descriptor)
        #expect(lifecycle.interaction(plan.id)?.plan == later)
        #expect(lifecycle.interaction(plan.id)?.plan?.revision == 1)
        await lifecycle.handle(.produced(plan.id, .plan(later)), from: ChangePlan.descriptor)
        #expect(lifecycle.interaction(plan.id)?.state == .planned)

        // Only withdrawn, for leaving.
        await lifecycle.handle(.lifecycle(plan.id, .failed), from: ChangePlan.descriptor)
        #expect(lifecycle.interaction(plan.id)?.state == .planned)
        await lifecycle.handle(.lifecycle(plan.id, .withdrawn), from: ChangePlan.descriptor)
        #expect(lifecycle.interaction(plan.id)?.state == .ended(.withdrawn))
    }

    /// P15-E requests 10 and 14: a plan is found by its origin; the skill
    /// that agreed it holds it, or a friend's Change the plan when they were
    /// added later.
    @Test func standingPlansAreFoundByOrigin() async throws {
        let plan = try planned()
        let origin = try #require(plan.plan?.origin)
        var joined = Interaction(skill: ChangePlan.descriptor.ref, role: .invitee, participants: [maya], createdAt: Timestamp(clock.now))
        try joined.apply(.proposalReady(SkillProposal(revision: 1, participants: [maya], terms: try Terms([.activity: .keywords([try Keyword("boba")])]))), at: Timestamp(clock.now))
        try joined.apply(.ownerAccepted(revision: 1), at: Timestamp(clock.now))
        try joined.apply(.everyoneConfirmed(revision: 1), at: Timestamp(clock.now))
        joined.record(.plan(try #require(plan.plan)))
        let plans = StandingPlans()

        let both = await coordinator([plan, joined])
        plans.attach(both)
        #expect(plans.standing(origin: origin)?.interaction == plan.id)
        #expect(plans.plan(origin: origin) == plan.plan)
        #expect(plans.standing(origin: ConversationID()) == nil)

        let onlyJoined = await coordinator([joined])
        plans.attach(onlyJoined)
        #expect(plans.standing(origin: origin)?.interaction == joined.id)
    }

    /// Change the plan starts from a plan's detail, never from New.
    @Test func newNeverOffersChangeThePlan() async throws {
        let registry = try SkillRegistry(SampleSkills.registry.descriptors + [ChangePlan.descriptor])
        let h = try await ComposerHarness(registry: registry)
        #expect(!h.model.tiles.contains { $0.id == .changePlan })
    }
}
