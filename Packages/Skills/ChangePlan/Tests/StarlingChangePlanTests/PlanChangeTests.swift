import Foundation
import StarlingChangePlan
import StarlingCore
import StarlingFakes
import Testing

@Suite struct PlanChangeTests {
    let plan = try! Plan(origin: ConversationID(), attendees: Attendees([Fixtures.alex, Fixtures.maya, Fixtures.jake]),
                         activity: Fixtures.boba, time: Fixtures.tonight)

    static func request(_ plan: Plan, _ encoded: (rules: OwnerRules, inputs: [Artifact])) -> SkillRequest {
        SkillRequest(
            interaction: InteractionID(), conversation: ConversationID(),
            intent: SkillIntent(skill: ChangePlan.descriptor.ref, rules: encoded.rules, audience: .picked([Fixtures.maya]), mode: .invite,
                                expiresAt: Timestamp(Fixtures.date(minutes: 30))),
            participants: [Fixtures.maya, Fixtures.jake], inputs: [.plan(plan)] + encoded.inputs, chainedFrom: plan.origin
        )
    }

    @Test func theDescriptorIsAnInviteOnlyChainWhileThePlanStands() {
        let descriptor = ChangePlan.descriptor
        #expect(descriptor.id == .changePlan)
        #expect(descriptor.chainTrigger == .whilePlanned)
        #expect(descriptor.sendModes == [.invite])
        #expect(descriptor.accepts == [.plan] && descriptor.produces == [.plan])
        #expect(descriptor.topicsUsed == [.time, .activity, .people])
        // Nothing must leave for it to run, so no Never setting blocks it.
        #expect(descriptor.topicsRequired.isEmpty)
        #expect(descriptor.permissions.isEmpty)
    }

    @Test func aChangeRoundTripsThroughTheRequest() throws {
        let changes: [PlanChange] = [
            .change(time: Fixtures.later, activity: nil, adding: nil),
            .change(time: nil, activity: Fixtures.dinner, adding: nil),
            .change(time: Fixtures.later, activity: Fixtures.dinner, adding: Fixtures.sam),
            .leave,
        ]
        for change in changes {
            let decoded = try PlanChange.decode(Self.request(plan, try change.encoded(for: plan)))
            #expect(decoded.change == change)
            #expect(decoded.basis == plan)
        }
    }

    @Test func theChangedPlanIsOneRevisionOn() throws {
        let changed = try PlanChange.change(time: Fixtures.later, activity: nil, adding: Fixtures.sam).applied(to: plan)
        #expect(changed.revision == plan.revision + 1)
        #expect(changed.id == plan.id && changed.origin == plan.origin)
        #expect(changed.time == Fixtures.later)
        #expect(changed.activity == Fixtures.boba)
        #expect(changed.attendees.peers == [Fixtures.alex, Fixtures.maya, Fixtures.jake, Fixtures.sam])
    }

    @Test func aChangeThatChangesNothingIsRefused() {
        for change in [PlanChange.change(time: nil, activity: nil, adding: nil),
                       .change(time: Fixtures.tonight, activity: Fixtures.boba, adding: nil),
                       .change(time: nil, activity: nil, adding: Fixtures.maya),
                       .leave] {
            #expect(throws: PlanChange.Invalid.nothingToChange) { try change.applied(to: plan) }
        }
    }

    @Test func aSuggestionWindowEndsByThePlansStart() {
        let now = Fixtures.date(minutes: 10)
        // Two hours would pass the plan's start (minute 90): it ends then.
        #expect(ChangePlan.defaultExpiry(for: plan, now: now) == Timestamp(Fixtures.tonight.start))
        // At least ten minutes, even right before the start.
        #expect(ChangePlan.defaultExpiry(for: plan, now: Fixtures.date(minutes: 89)) == Timestamp(Fixtures.date(minutes: 99)))
    }
}
