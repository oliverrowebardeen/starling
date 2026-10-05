import Foundation
import StarlingCore
import Testing

@Suite struct PlanChangeHoldsTests {
    let plan = ConversationID()
    let maya = ConversationID()
    let oliver = ConversationID()

    @Test func aSecondChangeWaitsUntilTheFirstEnds() async {
        let holds = PlanChangeHolds()
        #expect(await holds.hold(plan, for: maya))
        #expect(await !holds.hold(plan, for: oliver))
        #expect(await holds.holder(of: plan) == maya)
        await holds.release(plan, for: maya)
        #expect(await holds.hold(plan, for: oliver))
        #expect(await holds.holder(of: plan) == oliver)
    }

    @Test func holdingAgainForTheSameChangeIsFine() async {
        // A restored change holds the plan again, and a resend must not
        // lock out the change that already holds it.
        let holds = PlanChangeHolds()
        #expect(await holds.hold(plan, for: maya))
        #expect(await holds.hold(plan, for: maya))
    }

    @Test func onlyTheHolderCanRelease() async {
        let holds = PlanChangeHolds()
        #expect(await holds.hold(plan, for: maya))
        await holds.release(plan, for: oliver)
        #expect(await holds.holder(of: plan) == maya)
        await holds.release(ConversationID(), for: maya)
        #expect(await holds.holder(of: plan) == maya)
    }

    @Test func eachPlanIsHeldOnItsOwn() async {
        let holds = PlanChangeHolds()
        let another = ConversationID()
        #expect(await holds.hold(plan, for: maya))
        #expect(await holds.hold(another, for: oliver))
        #expect(await holds.holder(of: another) == oliver)
    }

    @Test func crossingChangesCannotBothCollectEveryYes() async {
        // ADR 0023: Maya and Oliver each start a change on the same plan.
        // Each suggester's phone holds the plan for its own change, so
        // neither can say yes to the other's, and at most one change can
        // reach everyone's yes.
        let mayasPhone = PlanChangeHolds()
        let oliversPhone = PlanChangeHolds()
        let jakesPhone = PlanChangeHolds()
        #expect(await mayasPhone.hold(plan, for: maya))
        #expect(await oliversPhone.hold(plan, for: oliver))
        let yesesForMaya = await [oliversPhone.hold(plan, for: maya), jakesPhone.hold(plan, for: maya)]
        let yesesForOliver = await [mayasPhone.hold(plan, for: oliver), jakesPhone.hold(plan, for: oliver)]
        #expect(!(yesesForMaya.allSatisfy { $0 } && yesesForOliver.allSatisfy { $0 }))
        #expect(yesesForMaya == [false, true])
        #expect(yesesForOliver == [false, false])
    }
}
