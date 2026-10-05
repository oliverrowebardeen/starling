import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingTransport
import Testing

/// One change to a plan at a time on each phone (ADR 0023): a pick on a
/// plan holds it from its first query, a friend holds it before a yes, and
/// every ending lets it go.
@Suite("One change to a plan at a time", .serialized)
struct PlanHoldTests {
    let quick = PickAPlaceConfiguration(retryInterval: .milliseconds(20), maxRetryInterval: .milliseconds(80),
                                        answerWindow: .seconds(3), confirmWindow: .milliseconds(600))
    let elsewhere = ConversationID()

    func friends() async throws -> (Group, oliver: Phone, maya: Phone, jake: Phone) {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all + [PlanChangeTests.greenBowl])
        let oliver = Phone("Oliver", hub: hub, maps: maps, configuration: quick)
        let maya = Phone("Maya", hub: hub, maps: maps, configuration: quick)
        let jake = Phone("Jake", hub: hub, maps: maps, configuration: quick)
        return (try await Group([oliver, maya, jake], hub: hub), oliver, maya, jake)
    }

    /// A plan at Boba Guys (or with no place yet), held on every phone.
    func plan(_ phones: [Phone], placed: Bool = true) async throws -> Plan {
        let plan = try Plan(origin: ConversationID(), attendees: Attendees(phones.map(\.id)), activity: kw("dinner"), time: nil)
        let held = placed ? try plan.updating(place: .some(Venues.bobaGuys.choice)) : plan
        for phone in phones { await phone.plans.hold(held) }
        return held
    }

    func change(_ plan: Plan, by organizer: Phone, with friends: [Phone]) async throws -> Interaction {
        try await organizer.organize([PlanChangeTests.greenBowl], with: friends, inputs: [.plan(plan)], chainedFrom: plan.origin)
    }

    func holders(of plan: Plan, on phones: [Phone]) async -> [ConversationID?] {
        var all: [ConversationID?] = []
        for phone in phones { all.append(await phone.holds.holder(of: plan.origin)) }
        return all
    }

    @Test func aChangeIsNotStartedWhileAnotherHoldsThePlan() async throws {
        let (group, oliver, maya, jake) = try await friends()
        defer { Task { await group.stop() } }
        let plan = try await plan([oliver, maya, jake])
        #expect(await oliver.holds.hold(plan.origin, for: elsewhere))
        await #expect(throws: PickAPlaceError.planChangeInProgress) { try await change(plan, by: oliver, with: [maya, jake]) }
        #expect(await group.wire.sent(by: oliver.id).isEmpty)

        await oliver.holds.release(plan.origin, for: elsewhere)
        let conversation = try await change(plan, by: oliver, with: [maya, jake]).conversation
        #expect(await oliver.holds.holder(of: plan.origin) == conversation)
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func noYesGoesOutWhileAnotherChangeHoldsThePlan() async throws {
        let (group, oliver, maya, jake) = try await friends()
        defer { Task { await group.stop() } }
        let plan = try await plan([oliver, maya, jake])
        let conversation = try await change(plan, by: oliver, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }

        #expect(await maya.holds.hold(plan.origin, for: elsewhere))
        await #expect(throws: PickAPlaceError.planChangeInProgress) { try await maya.accept(in: conversation) }
        #expect(await group.wire.sent(by: maya.id).allSatisfy { $0.conversation != conversation || $0.body.kind != .accept })
        #expect(await maya.state(in: conversation) == .proposed)

        await maya.holds.release(plan.origin, for: elsewhere)
        for phone in [maya, jake, oliver] { try await phone.accept(in: conversation) }
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.planned, in: conversation), "\(phone.name)") }
        #expect(await group.lifecyclesWereLegal())
    }

    /// Planned, nobody up, and withdrawn all let the plan go on every
    /// phone; a plan's first place holds it too.
    @Test func everyEndingReleasesThePlan() async throws {
        let (group, oliver, maya, jake) = try await friends()
        defer { Task { await group.stop() } }
        let everyone = [oliver, maya, jake]

        let first = try await plan(everyone, placed: false)
        let placing = try await change(first, by: oliver, with: [maya, jake]).conversation
        #expect(await oliver.holds.holder(of: first.origin) == placing)
        for phone in everyone { #expect(await phone.reaches(.proposed, in: placing), "\(phone.name)") }
        for phone in [maya, jake, oliver] { try await phone.accept(in: placing) }
        for phone in everyone { #expect(await phone.reaches(.planned, in: placing), "\(phone.name)") }
        #expect(await eventually { await holders(of: first, on: everyone) == [nil, nil, nil] })

        let plan = try await plan(everyone)
        let passed = try await change(plan, by: oliver, with: [maya, jake]).conversation
        for phone in everyone { #expect(await phone.reaches(.proposed, in: passed), "\(phone.name)") }
        try await maya.accept(in: passed)
        try await jake.pass(in: passed)
        try await oliver.accept(in: passed)
        #expect(await oliver.reaches(.ended(.nobodyUp), in: passed))
        #expect(await eventually { await holders(of: plan, on: everyone) == [nil, nil, nil] })

        let withdrawn = try await change(plan, by: oliver, with: [maya, jake])
        for phone in everyone { #expect(await phone.reaches(.proposed, in: withdrawn.conversation), "\(phone.name)") }
        try await maya.accept(in: withdrawn.conversation)
        await oliver.service.withdraw(withdrawn.id)
        // Withdrawn while asking: Maya hears the ordinary no.
        #expect(await oliver.reaches(.ended(.withdrawn), in: withdrawn.conversation))
        #expect(await maya.reaches(.ended(.nobodyUp), in: withdrawn.conversation))
        #expect(await eventually { await holders(of: plan, on: everyone) == [nil, nil, nil] })
        #expect(await group.lifecyclesWereLegal())
    }

    /// ADR 0023's case: Oliver and Maya each start a change on the same
    /// plan. Each holds the plan for its own, so neither can say yes to the
    /// other's, and both end with the plan as it was.
    @Test func twoCrossingChangesBothLeaveThePlanAsItWas() async throws {
        let (group, oliver, maya, jake) = try await friends()
        defer { Task { await group.stop() } }
        let plan = try await plan([oliver, maya, jake])
        let olivers = try await change(plan, by: oliver, with: [maya, jake]).conversation
        let mayas = try await change(plan, by: maya, with: [oliver, jake]).conversation
        for phone in [oliver, maya, jake] {
            #expect(await phone.reaches(.proposed, in: olivers), "\(phone.name)")
            #expect(await phone.reaches(.proposed, in: mayas), "\(phone.name)")
        }
        await #expect(throws: PickAPlaceError.planChangeInProgress) { try await oliver.accept(in: mayas) }
        await #expect(throws: PickAPlaceError.planChangeInProgress) { try await maya.accept(in: olivers) }
        try await jake.accept(in: olivers)
        await #expect(throws: PickAPlaceError.planChangeInProgress) { try await jake.accept(in: mayas) }
        try await oliver.accept(in: olivers)
        try await maya.accept(in: mayas)

        #expect(await oliver.reaches(.ended(.nobodyUp), in: olivers))
        #expect(await maya.reaches(.ended(.nobodyUp), in: mayas))
        for phone in [oliver, maya, jake] {
            #expect(await phone.agreedPlace(in: olivers) == nil, "\(phone.name)")
            #expect(await phone.agreedPlace(in: mayas) == nil, "\(phone.name)")
        }
        #expect(await eventually { await holders(of: plan, on: [oliver, maya, jake]) == [nil, nil, nil] })
        #expect(await group.lifecyclesWereLegal())
    }

    /// Holds are not saved. A restored organizer holds the plan again; one
    /// that finds another change holding it ends with the plan as it was.
    @Test(arguments: [false, true])
    func aRestoredOrganizerHoldsThePlanAgain(anotherHoldsIt: Bool) async throws {
        let (group, oliver, maya, jake) = try await friends()
        defer { Task { await group.stop() } }
        let plan = try await plan([oliver, maya, jake])
        let conversation = try await change(plan, by: oliver, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }

        let elsewhere = elsewhere
        await oliver.restart { holds in if anotherHoldsIt { _ = await holds.hold(plan.origin, for: elsewhere) } }
        if anotherHoldsIt {
            #expect(await oliver.reaches(.ended(.nobodyUp), in: conversation))
            #expect(await oliver.holds.holder(of: plan.origin) == elsewhere)
        } else {
            #expect(await oliver.holds.holder(of: plan.origin) == conversation)
            for phone in [maya, jake, oliver] { try await phone.accept(in: conversation) }
            for phone in [oliver, maya, jake] { #expect(await phone.reaches(.planned, in: conversation), "\(phone.name)") }
        }
        #expect(await group.lifecyclesWereLegal())
    }

    /// A friend's yes holds the plan again after a relaunch, or its card
    /// ends if another change holds the plan.
    @Test(arguments: [false, true])
    func aRestoredYesHoldsThePlanAgain(anotherHoldsIt: Bool) async throws {
        let (group, oliver, maya, jake) = try await friends()
        defer { Task { await group.stop() } }
        let plan = try await plan([oliver, maya, jake])
        let conversation = try await change(plan, by: oliver, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))

        let elsewhere = elsewhere
        await maya.restart { holds in if anotherHoldsIt { _ = await holds.hold(plan.origin, for: elsewhere) } }
        if anotherHoldsIt {
            #expect(await maya.reaches(.ended(.nobodyUp), in: conversation))
        } else {
            #expect(await maya.holds.holder(of: plan.origin) == conversation)
        }
        #expect(await group.lifecyclesWereLegal())
    }

}
