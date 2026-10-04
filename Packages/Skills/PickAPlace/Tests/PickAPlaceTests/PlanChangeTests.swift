import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingTransport
import Testing

/// "Somewhere else?": Pick a place on a confirmed plan changes the plan's
/// place, and a new budget is a limit for that search. Once the plan has a
/// place, everyone in it must agree to a new one; otherwise the plan stays
/// as it was (ADR 0022, ADR 0233).
@Suite("Changing a plan's place", .serialized)
struct PlanChangeTests {
    static let greenBowl = candidate("Green Bowl", id: "I.greenbowl", tier: .two, diets: ["vegetarian"], kinds: ["restaurant"])
    static let veggieCart = candidate("Veggie Cart", id: "I.veggiecart", tier: .one, diets: ["vegetarian"], kinds: ["food truck"])

    let quick = PickAPlaceConfiguration(retryInterval: .milliseconds(20), maxRetryInterval: .milliseconds(80),
                                        answerWindow: .seconds(3), confirmWindow: .milliseconds(600))

    /// Oliver organizes; Maya keeps a $20 budget; Jake needs vegetarian.
    func friends(
        sam: Bool = false, jakeSkills: [SkillRef] = [PickAPlaceSkill.ref], configuration: PickAPlaceConfiguration = fastConfiguration
    ) async throws -> (Group, oliver: Phone, maya: Phone, jake: Phone, sam: Phone?) {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all + [Self.greenBowl, Self.veggieCart])
        let oliver = Phone("Oliver", hub: hub, maps: maps, configuration: configuration)
        let maya = Phone("Maya", hub: hub, maps: maps, limits: limits(budget: 20), configuration: configuration)
        let jake = Phone("Jake", hub: hub, maps: maps, limits: limits(needs: ["vegetarian"]), skills: jakeSkills, configuration: configuration)
        let other = sam ? Phone("Sam", hub: hub, maps: maps, configuration: configuration) : nil
        let group = try await Group([oliver, maya, jake] + (other.map { [$0] } ?? []), hub: hub)
        return (group, oliver, maya, jake, other)
    }

    func dinner(_ people: [Phone], at place: PlaceCandidate? = nil) throws -> Plan {
        let plan = try Plan(origin: ConversationID(), attendees: Attendees(people.map(\.id)), activity: kw("dinner"),
                            time: TimeSlot(start: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_790_003_600)))
        return try place.map { try plan.updating(place: .some($0.choice)) } ?? plan
    }

    func places(sentBy phone: Phone, in conversation: ConversationID, _ group: Group) async -> [[PlaceChoice]] {
        await group.wire.sent(by: phone.id).filter { $0.conversation == conversation }.compactMap {
            if case .query(let query) = $0.body, case .places(let list) = query.candidates { list } else { nil }
        }
    }

    @Test func pickingTwiceOnAPlanRaisesItsRevisionEachTimeAndTakesANewBudget() async throws {
        let (group, oliver, maya, jake, _) = try await friends()
        defer { Task { await group.stop() } }
        let everyone = [oliver, maya, jake]
        let plan = try dinner(everyone)

        // The first pick puts the plan at Green Bowl.
        let first = try await oliver.organize([Self.greenBowl, Self.veggieCart], with: [maya, jake], inputs: [.plan(plan)],
                                              chainedFrom: plan.origin).conversation
        for phone in everyone { #expect(await phone.reaches(.proposed, in: first), "\(phone.name)") }
        let placed = try #require(await oliver.interaction(first)?.proposal?.plan)
        #expect(placed.id == plan.id && placed.revision == plan.revision + 1)
        #expect(placed.place == Self.greenBowl.choice && placed.attendees == plan.attendees)
        #expect(placed.time == plan.time && placed.activity == plan.activity)
        for phone in everyone { try await phone.accept(in: first) }
        for phone in everyone {
            #expect(await phone.reaches(.planned, in: first), "\(phone.name)")
            #expect(await eventually { await phone.agreedPlace(in: first) == Self.greenBowl.choice })
        }

        // "Somewhere else?" on the updated plan, with a new $10 limit.
        let second = try await oliver.organize([Self.greenBowl, Self.veggieCart], with: [maya, jake], limits: limits(budget: 10),
                                               inputs: [.plan(placed)], chainedFrom: plan.origin).conversation
        for phone in everyone { #expect(await phone.reaches(.proposed, in: second), "\(phone.name)") }
        // Green Bowl is over the new limit, so only Veggie Cart was asked
        // about, and the limit itself never left the phone.
        let asked = await places(sentBy: oliver, in: second, group)
        #expect(!asked.isEmpty && asked.allSatisfy { $0 == [Self.veggieCart.choice] })
        #expect(await group.wire.values.allSatisfy { $0.0 != .budget })
        let moved = try #require(await oliver.interaction(second)?.proposal?.plan)
        #expect(moved.id == plan.id && moved.revision == placed.revision + 1)
        #expect(moved.place == Self.veggieCart.choice && moved.attendees == plan.attendees)
        for phone in everyone { try await phone.accept(in: second) }
        for phone in everyone {
            #expect(await phone.reaches(.planned, in: second), "\(phone.name)")
            // The place and the roster follow the confirmation as their own events.
            #expect(await eventually { await phone.agreedPlace(in: second) == Self.veggieCart.choice })
            #expect(await eventually { await phone.attendees(in: second).map(Set.init) == Set(plan.attendees.peers) })
        }
        #expect(await group.lifecyclesWereLegal())
    }

    /// Le Fancy breaks Maya's budget. Without a plan, Oliver and Jake would
    /// go without her; on a plan, the place does not change at all.
    @Test func aPlaceThatDoesNotFitEveryoneLeavesThePlanAsItWas() async throws {
        let (group, oliver, maya, jake, _) = try await friends()
        defer { Task { await group.stop() } }
        let plan = try dinner([oliver, maya, jake], at: Venues.bobaGuys)

        let conversation = try await oliver.organize([Venues.fancy], with: [maya, jake], inputs: [.plan(plan)],
                                                     chainedFrom: plan.origin).conversation
        #expect(await oliver.reaches(.ended(.nobodyUp), in: conversation))
        #expect(await group.wire.envelopes.allSatisfy { $0.body.kind != .propose })
        for phone in [oliver, maya, jake] {
            #expect(await phone.agreedPlace(in: conversation) == nil, "\(phone.name)")
            #expect(await phone.interaction(conversation)?.proposal == nil, "\(phone.name)")
        }
        #expect(await group.lifecyclesWereLegal())
    }

    /// A plan from Down for... has no place yet. Its first place still goes
    /// ahead with whoever it fits, as a chain does (ADR 0233): Le Fancy
    /// breaks Maya's budget, so the plan moves on with Oliver and Jake, and
    /// its revision still rises.
    @Test func theFirstPlaceForAPlanGoesAheadWithWhoeverItFits() async throws {
        let (group, oliver, maya, jake, _) = try await friends(configuration: quick)
        defer { Task { await group.stop() } }
        let plan = try dinner([oliver, maya, jake])
        #expect(plan.place == nil)

        let conversation = try await oliver.organize([Venues.fancy], with: [maya, jake], inputs: [.plan(plan)],
                                                     chainedFrom: plan.origin).conversation
        for phone in [oliver, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }
        let placed = try #require(await oliver.interaction(conversation)?.proposal?.plan)
        #expect(placed.id == plan.id && placed.revision == plan.revision + 1 && placed.place == Venues.fancy.choice)
        #expect(Set(placed.attendees.peers) == [oliver.id, jake.id])
        #expect(await oliver.service.organized[conversation]?.everyoneMustAgree == false)
        for phone in [oliver, jake] { try await phone.accept(in: conversation) }
        for phone in [oliver, jake] { #expect(await phone.reaches(.planned, in: conversation), "\(phone.name)") }
        #expect(await eventually { await oliver.attendees(in: conversation) == [oliver.id, jake.id] })
        #expect(await group.lifecyclesWereLegal())
    }

    /// The rule is kept with the request's deadlines, so a relaunch keeps
    /// it; a record saved before it existed reads as a first place.
    @Test func deadlinesSavedBeforeTheRuleReadAsAFirstPlace() throws {
        let saved = RequestDeadlines(expiresAt: Date(timeIntervalSince1970: 1_790_000_000), everyoneMustAgree: true)
        #expect(try JSONDecoder().decode(RequestDeadlines.self, from: JSONEncoder().encode(saved)) == saved)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        old.removeValue(forKey: "everyoneMustAgree")
        let read = try JSONDecoder().decode(RequestDeadlines.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(!read.everyoneMustAgree && read.expiresAt == saved.expiresAt)
    }

    /// Everyone is shown Green Bowl, and Jake passes. A pass looks like
    /// silence, so the change ends at the confirm deadline, and nobody's
    /// plan moves.
    @Test func aPassOnTheNewPlaceLeavesThePlanAsItWas() async throws {
        let (group, oliver, maya, jake, _) = try await friends(configuration: quick)
        defer { Task { await group.stop() } }
        let plan = try dinner([oliver, maya, jake], at: Venues.bobaGuys)

        let conversation = try await oliver.organize([Self.greenBowl], with: [maya, jake], inputs: [.plan(plan)],
                                                     chainedFrom: plan.origin).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }
        try await maya.accept(in: conversation)
        try await oliver.accept(in: conversation)
        try await jake.pass(in: conversation)

        #expect(await oliver.reaches(.ended(.nobodyUp), in: conversation))
        #expect(await maya.reaches(.ended(.nobodyUp), in: conversation))
        #expect(await jake.state(in: conversation) == .ended(.declined))
        for phone in [oliver, maya, jake] { #expect(await phone.agreedPlace(in: conversation) == nil, "\(phone.name)") }
        #expect(await group.lifecyclesWereLegal())
    }

    /// Maya takes her yes back, and it crosses the confirmation. Without a
    /// plan, Oliver and Jake would keep it for two; a change needs
    /// everyone, so it is off for everyone.
    @Test func aYesTakenBackAfterTheConfirmationCallsTheChangeOff() async throws {
        let (group, oliver, maya, jake, _) = try await friends(configuration: quick)
        defer { Task { await group.stop() } }
        let plan = try dinner([oliver, maya, jake], at: Venues.bobaGuys)
        let conversation = try await oliver.organize([Self.greenBowl], with: [maya, jake], inputs: [.plan(plan)],
                                                     chainedFrom: plan.origin).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }
        try await maya.accept(in: conversation)
        try await jake.accept(in: conversation)
        #expect(await eventually { await oliver.service.organized[conversation]?.accepted == [maya.id, jake.id] })

        await maya.transport.lose(3) { $0.body.kind == .reject }
        try await maya.pass(in: conversation)
        #expect(await maya.reaches(.ended(.withdrawn), in: conversation))
        try await oliver.accept(in: conversation)

        #expect(await oliver.reaches(.ended(.failed), in: conversation))
        #expect(await jake.reaches(.ended(.withdrawn), in: conversation))
        #expect(await eventually { await maya.service.pendingWithdrawals.isEmpty })
        #expect(await group.lifecyclesWereLegal())
    }

    /// Jake's phone cannot run Pick a place, so he could never agree: the
    /// change ends before anything is sent. Sam is named but is not in the
    /// plan, so he is never asked.
    @Test func onlyThePlansPeopleAreAskedAndAllOfThemMustBeAble() async throws {
        let (group, oliver, maya, jake, sam) = try await friends(sam: true)
        defer { Task { await group.stop() } }
        let sam_ = try #require(sam)
        let plan = try dinner([oliver, maya, jake], at: Venues.bobaGuys)

        let outside = try await oliver.organize([Self.greenBowl], with: [maya, jake, sam_], inputs: [.plan(plan)],
                                                chainedFrom: plan.origin).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: outside), "\(phone.name)") }
        #expect(await group.wire.sent(to: sam_.id).isEmpty)
        let card = try #require(await oliver.interaction(outside)?.proposal)
        #expect(Set(card.participants) == Set(plan.attendees.peers))
        await group.stop()

        let (others, oliver2, maya2, jake2, _) = try await friends(jakeSkills: [])
        defer { Task { await others.stop() } }
        let plan2 = try dinner([oliver2, maya2, jake2], at: Venues.bobaGuys)
        let blocked = try await oliver2.organize([Self.greenBowl], with: [maya2, jake2], inputs: [.plan(plan2)],
                                                 chainedFrom: plan2.origin).conversation
        #expect(await oliver2.reaches(.ended(.unsupported), in: blocked))
        #expect(await others.wire.sent(by: oliver2.id).isEmpty)
        #expect(await others.lifecyclesWereLegal())
    }

    /// After a restart, an organizer that was changing a plan still needs
    /// everyone: Jake never answers, so there is no plan for two.
    @Test func aRestoredChangeStillNeedsEveryone() async throws {
        let (group, oliver, maya, jake, _) = try await friends(configuration: quick)
        defer { Task { await group.stop() } }
        let plan = try dinner([oliver, maya, jake], at: Venues.bobaGuys)
        let conversation = try await oliver.organize([Self.greenBowl], with: [maya, jake], inputs: [.plan(plan)],
                                                     chainedFrom: plan.origin).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }
        try await maya.accept(in: conversation)
        #expect(await eventually { await oliver.service.organized[conversation]?.accepted == [maya.id] })

        await oliver.restart()
        #expect(await oliver.service.organized[conversation]?.everyoneMustAgree == true)
        try await oliver.accept(in: conversation)
        #expect(await oliver.reaches(.ended(.nobodyUp), in: conversation))
        #expect(await oliver.agreedPlace(in: conversation) == nil)
        #expect(await group.lifecyclesWereLegal())
    }
}
