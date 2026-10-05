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

    /// Each phone holds its own copy of the plan, as after agreeing it.
    func share(_ plan: Plan, with phones: [Phone]) async {
        for phone in phones { await phone.plans.hold(plan) }
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
        await share(plan, with: everyone)

        // The first pick puts the plan at Green Bowl.
        let first = try await oliver.organize([Self.greenBowl, Self.veggieCart], with: [maya, jake], inputs: [.plan(plan)],
                                              chainedFrom: plan.origin).conversation
        for phone in everyone { #expect(await phone.reaches(.proposed, in: first), "\(phone.name)") }
        let placed = try #require(await oliver.interaction(first)?.proposal?.plan)
        #expect(placed.id == plan.id && placed.revision == plan.revision + 1)
        #expect(placed.place == Self.greenBowl.choice && placed.attendees == plan.attendees)
        #expect(placed.time == plan.time && placed.activity == plan.activity)
        // Every phone's agreed plan names the same new revision, so each
        // applies it once, and only over the revision before (ADR 0233).
        for friend in [maya, jake] { #expect(await friend.interaction(first)?.proposal?.plan?.revision == placed.revision, "\(friend.name)") }
        for phone in everyone { try await phone.accept(in: first) }
        for phone in everyone {
            #expect(await phone.reaches(.planned, in: first), "\(phone.name)")
            #expect(await eventually { await phone.agreedPlace(in: first) == Self.greenBowl.choice })
        }

        // "Somewhere else?" on the updated plan, with a new $10 limit. Each
        // phone holds the plan at Green Bowl now.
        await share(placed, with: everyone)
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
        for friend in [maya, jake] { #expect(await friend.interaction(second)?.proposal?.plan?.revision == moved.revision, "\(friend.name)") }
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
        await share(plan, with: [oliver, maya, jake])

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
        await share(plan, with: [oliver, maya, jake])

        let conversation = try await oliver.organize([Venues.fancy], with: [maya, jake], inputs: [.plan(plan)],
                                                     chainedFrom: plan.origin).conversation
        for phone in [oliver, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }
        let placed = try #require(await oliver.interaction(conversation)?.proposal?.plan)
        #expect(placed.id == plan.id && placed.revision == plan.revision + 1 && placed.place == Venues.fancy.choice)
        #expect(Set(placed.attendees.peers) == [oliver.id, jake.id])
        #expect(await oliver.service.organized[conversation]?.everyoneMustAgree == false)
        #expect(await jake.interaction(conversation)?.proposal?.plan?.revision == placed.revision)
        for phone in [oliver, jake] { try await phone.accept(in: conversation) }
        for phone in [oliver, jake] { #expect(await phone.reaches(.planned, in: conversation), "\(phone.name)") }
        #expect(await eventually { await oliver.attendees(in: conversation) == [oliver.id, jake.id] })
        #expect(await group.lifecyclesWereLegal())
    }

    /// The revision travels in the proposal's round, which stays below
    /// `ProtocolLimits.maxNegotiationRounds`: a plan at its last revision
    /// that fits, or any above it, takes no further place, nothing is sent,
    /// and nothing overflows (review of #118, finding 4).
    @Test func aPlanAtTheRevisionLimitTakesNoFurtherPlace() async throws {
        let (group, oliver, maya, jake, _) = try await friends()
        defer { Task { await group.stop() } }
        let last = UInt32(ProtocolLimits.maxNegotiationRounds) - 1
        let base = try dinner([oliver, maya, jake], at: Venues.bobaGuys)
        for revision in [last, UInt32.max] {
            let full = try Plan(id: base.id, origin: base.origin, attendees: base.attendees, activity: base.activity, time: base.time,
                                place: base.place, revision: revision)
            await #expect(throws: PickAPlaceError.planRevisionLimit, "revision \(revision)") {
                try await oliver.organize([Self.greenBowl], with: [maya, jake], inputs: [.plan(full)], chainedFrom: base.origin)
            }
        }
        #expect(await group.wire.sent(by: oliver.id).isEmpty)

        // One below the limit still works, and the friends' plans name it.
        let almost = try Plan(id: base.id, origin: base.origin, attendees: base.attendees, activity: base.activity, time: base.time,
                              place: base.place, revision: last - 1)
        await share(almost, with: [oliver, maya, jake])
        let conversation = try await oliver.organize([Self.greenBowl], with: [maya, jake], inputs: [.plan(almost)],
                                                     chainedFrom: base.origin).conversation
        for phone in [oliver, maya, jake] {
            #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)")
            #expect(await phone.interaction(conversation)?.proposal?.plan?.revision == last, "\(phone.name)")
        }
        #expect(await group.lifecyclesWereLegal())
    }

    /// Everyone is shown Green Bowl, and Jake passes. A pass looks like
    /// silence, so the change ends at the confirm deadline, and nobody's
    /// plan moves.
    @Test func aPassOnTheNewPlaceLeavesThePlanAsItWas() async throws {
        let (group, oliver, maya, jake, _) = try await friends(configuration: quick)
        defer { Task { await group.stop() } }
        let plan = try dinner([oliver, maya, jake], at: Venues.bobaGuys)
        await share(plan, with: [oliver, maya, jake])

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

    /// The Orchestrator's decision on the review of #118: a yes to a change
    /// of place is final once sent. Maya cannot pass or withdraw after it;
    /// a withdrawal that arrives after everyone said yes is ignored; and
    /// nobody, the organizer included, can call a confirmed change off.
    @Test func aYesToAPlaceChangeIsFinal() async throws {
        let (group, oliver, maya, jake, _) = try await friends(configuration: quick)
        defer { Task { await group.stop() } }
        let plan = try dinner([oliver, maya, jake], at: Venues.bobaGuys)
        await share(plan, with: [oliver, maya, jake])
        let conversation = try await oliver.organize([Self.greenBowl], with: [maya, jake], inputs: [.plan(plan)],
                                                     chainedFrom: plan.origin).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))
        await #expect(throws: PickAPlaceError.yesIsFinal) { try await maya.pass(in: conversation) }
        let mayas = try #require(await maya.interaction(conversation)?.id)
        await maya.service.withdraw(mayas)
        #expect(await maya.state(in: conversation) == .confirmed)

        try await jake.accept(in: conversation)
        try await oliver.accept(in: conversation)
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.planned, in: conversation), "\(phone.name)") }

        // A no from Maya after the confirmation, as a crossing withdrawal
        // would arrive, and withdrawals on both sides: nothing changes.
        _ = try await maya.outbox.send(.reject(Rejection(proposal: MessageID(), reason: .noOverlap)), to: oliver.id,
                                       conversation: conversation, skill: PickAPlaceSkill.ref, mode: .invite, chainedFrom: plan.origin)
        await maya.service.withdraw(mayas)
        let olivers = try #require(await oliver.interaction(conversation)?.id)
        await oliver.service.withdraw(olivers)
        try await Task.sleep(for: .milliseconds(300))
        for phone in [oliver, maya, jake] {
            #expect(await phone.state(in: conversation) == .planned, "\(phone.name)")
            #expect(await phone.attendees(in: conversation).map(Set.init) == Set(plan.attendees.peers), "\(phone.name)")
        }
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
        await share(plan, with: [oliver, maya, jake])

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
        await share(plan2, with: [oliver2, maya2, jake2])
        let blocked = try await oliver2.organize([Self.greenBowl], with: [maya2, jake2], inputs: [.plan(plan2)],
                                                 chainedFrom: plan2.origin).conversation
        #expect(await oliver2.reaches(.ended(.unsupported), in: blocked))
        #expect(await others.wire.sent(by: oliver2.id).isEmpty)
        #expect(await others.lifecyclesWereLegal())
    }

    enum Record: String, CaseIterable, Sendable { case kept, missing, unreadable }

    /// Makes `phone`'s record of the request's kind kept, missing, or
    /// unreadable, before it restarts.
    func prepare(_ record: Record, on phone: Phone, for conversation: ConversationID) async {
        switch record {
        case .kept: break
        case .missing: await phone.ledger.forgetRequestKind(for: conversation)
        case .unreadable: await phone.ledger.setFailing(true)
        }
    }

    /// After a restart, an organizer that was changing a plan still needs
    /// everyone, even when its record of that is gone (review of #118,
    /// finding 1): Jake never answers, so there is no plan for two.
    @Test(arguments: [Record.kept, .missing])
    func aRestoredChangeStillNeedsEveryone(record: Record) async throws {
        let (group, oliver, maya, jake, _) = try await friends(configuration: quick)
        defer { Task { await group.stop() } }
        let plan = try dinner([oliver, maya, jake], at: Venues.bobaGuys)
        await share(plan, with: [oliver, maya, jake])
        let conversation = try await oliver.organize([Self.greenBowl], with: [maya, jake], inputs: [.plan(plan)],
                                                     chainedFrom: plan.origin).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }
        try await maya.accept(in: conversation)
        #expect(await eventually { await oliver.service.organized[conversation]?.accepted == [maya.id] })

        await prepare(record, on: oliver, for: conversation)
        await oliver.restart()
        #expect(await oliver.service.organized[conversation]?.everyoneMustAgree == true)
        try await oliver.accept(in: conversation)
        #expect(await oliver.reaches(.ended(.nobodyUp), in: conversation))
        #expect(await oliver.agreedPlace(in: conversation) == nil)
        #expect(await group.lifecyclesWereLegal())
    }

    /// A confirmed change restored with its record kept, missing, or
    /// unreadable is still a change: a withdrawal that arrives afterwards
    /// changes nothing.
    @Test(arguments: Record.allCases)
    func aRestoredConfirmedChangeStaysFinal(record: Record) async throws {
        let (group, oliver, maya, jake, _) = try await friends(configuration: quick)
        defer { Task { await group.stop() } }
        let plan = try dinner([oliver, maya, jake], at: Venues.bobaGuys)
        await share(plan, with: [oliver, maya, jake])
        let conversation = try await oliver.organize([Self.greenBowl], with: [maya, jake], inputs: [.plan(plan)],
                                                     chainedFrom: plan.origin).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }
        for phone in [maya, jake, oliver] { try await phone.accept(in: conversation) }
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.planned, in: conversation), "\(phone.name)") }
        #expect(await eventually { await oliver.attendees(in: conversation).map(Set.init) == Set(plan.attendees.peers) })

        await prepare(record, on: oliver, for: conversation)
        await oliver.restart()
        #expect(await oliver.service.organized[conversation]?.everyoneMustAgree == true)
        _ = try await maya.outbox.send(.reject(Rejection(proposal: MessageID(), reason: .noOverlap)), to: oliver.id,
                                       conversation: conversation, skill: PickAPlaceSkill.ref, mode: .invite, chainedFrom: plan.origin)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await oliver.state(in: conversation) == .planned)
        #expect(await oliver.attendees(in: conversation).map(Set.init) == Set(plan.attendees.peers))
        #expect(await jake.attendees(in: conversation).map(Set.init) == Set(plan.attendees.peers))
        #expect(await group.lifecyclesWereLegal())
    }

    /// Round 2, item 2: a yes is final from the moment it is on its way.
    /// Maya's yes reaches Oliver while her own send has not returned (the
    /// audit journal holds it); she cannot pass or withdraw then, so both
    /// phones end with the same plan.
    @Test func aYesOnItsWayIsAlreadyFinal() async throws {
        let (group, oliver, maya, jake, _) = try await friends(configuration: quick)
        defer { Task { await maya.hold.release(); await group.stop() } }
        let plan = try dinner([oliver, maya, jake], at: Venues.bobaGuys)
        await share(plan, with: [oliver, maya, jake])
        let conversation = try await oliver.organize([Self.greenBowl], with: [maya, jake], inputs: [.plan(plan)],
                                                     chainedFrom: plan.origin).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }

        await maya.hold.hold([.accept])
        let yes = Task { try await maya.accept(in: conversation) }
        #expect(await eventually { await oliver.service.organized[conversation]?.accepted.contains(maya.id) == true })
        await #expect(throws: PickAPlaceError.yesIsFinal) { try await maya.pass(in: conversation) }
        let mayas = try #require(await maya.interaction(conversation)?.id)
        await maya.service.withdraw(mayas)

        try await jake.accept(in: conversation)
        try await oliver.accept(in: conversation)
        #expect(await oliver.reaches(.planned, in: conversation))
        await maya.hold.release()
        try await yes.value
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.planned, in: conversation), "\(phone.name)") }
        #expect(await group.lifecyclesWereLegal())
    }

    /// Round 2, item 4: two changes over the same revision. Once the plan
    /// has moved on, a friend's yes to the older change does not go out,
    /// and the organizer does not confirm it.
    @Test func aChangeOverAnOlderRevisionDoesNotApply() async throws {
        let (group, oliver, maya, jake, _) = try await friends(configuration: quick)
        defer { Task { await group.stop() } }
        let plan = try dinner([oliver, maya, jake], at: Venues.bobaGuys)
        let movedOn = try plan.updating(place: .some(Venues.teaLab.choice))

        // A friend: Maya's plan moved on before she taps.
        await share(plan, with: [oliver, maya, jake])
        let firstRequest = try await oliver.organize([Self.greenBowl], with: [maya, jake], inputs: [.plan(plan)], chainedFrom: plan.origin)
        let first = firstRequest.conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: first), "\(phone.name)") }
        await maya.plans.hold(movedOn)
        await #expect(throws: PickAPlaceError.planChangedMeanwhile) { try await maya.accept(in: first) }
        #expect(await maya.reaches(.ended(.nobodyUp), in: first))
        #expect(await group.wire.sent(by: maya.id).allSatisfy { $0.conversation != first || $0.body.kind != .accept })

        // The organizer: everyone said yes, but Oliver's plan moved on.
        // The first change ends first: one change to a plan at a time.
        await oliver.service.withdraw(firstRequest.id)
        #expect(await eventually { await oliver.holds.holder(of: plan.origin) == nil })
        await share(plan, with: [oliver, maya, jake])
        let second = try await oliver.organize([Self.greenBowl], with: [maya, jake], inputs: [.plan(plan)], chainedFrom: plan.origin).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: second), "\(phone.name)") }
        try await maya.accept(in: second)
        try await jake.accept(in: second)
        #expect(await eventually { await oliver.service.organized[second]?.accepted == [maya.id, jake.id] })
        await oliver.plans.hold(movedOn)
        try await oliver.accept(in: second)
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.ended(.nobodyUp), in: second), "\(phone.name)") }
        #expect(await group.lifecyclesWereLegal())
    }

    /// Follow-up to round 2: the plan moved to another place while its
    /// stored revision lagged (still the same number). The change records
    /// the plan's place too, so the friend's yes and the organizer's
    /// confirmation are still stopped.
    @Test func aChangeIsCaughtByThePlacesEvenIfTheRevisionLags() async throws {
        let (group, oliver, maya, jake, _) = try await friends(configuration: quick)
        defer { Task { await group.stop() } }
        let plan = try dinner([oliver, maya, jake], at: Venues.bobaGuys)
        let elsewhere = try Plan(id: plan.id, origin: plan.origin, attendees: plan.attendees, activity: plan.activity, time: plan.time,
                                 place: Venues.teaLab.choice, revision: plan.revision)

        await share(plan, with: [oliver, maya, jake])
        let firstRequest = try await oliver.organize([Self.greenBowl], with: [maya, jake], inputs: [.plan(plan)], chainedFrom: plan.origin)
        let first = firstRequest.conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: first), "\(phone.name)") }
        await maya.plans.hold(elsewhere)
        await #expect(throws: PickAPlaceError.planChangedMeanwhile) { try await maya.accept(in: first) }
        #expect(await maya.reaches(.ended(.nobodyUp), in: first))

        await oliver.service.withdraw(firstRequest.id)
        #expect(await eventually { await oliver.holds.holder(of: plan.origin) == nil })
        await share(plan, with: [oliver, maya, jake])
        let second = try await oliver.organize([Self.greenBowl], with: [maya, jake], inputs: [.plan(plan)], chainedFrom: plan.origin).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: second), "\(phone.name)") }
        try await maya.accept(in: second)
        try await jake.accept(in: second)
        #expect(await eventually { await oliver.service.organized[second]?.accepted == [maya.id, jake.id] })
        await oliver.plans.hold(elsewhere)
        try await oliver.accept(in: second)
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.ended(.nobodyUp), in: second), "\(phone.name)") }
        #expect(await group.lifecyclesWereLegal())
    }

    /// Codex round 2 on #118: Maya's yes went out, but her app stopped
    /// before her card showed it. Restored, her yes stands (it is recorded
    /// once sent): it cannot be taken back, and the plan goes ahead.
    @Test func aYesRecordedBeforeARestartStandsEvenIfTheCardDidNotShowIt() async throws {
        let (group, oliver, maya, jake, _) = try await friends(configuration: quick)
        defer { Task { await group.stop() } }
        let plan = try dinner([oliver, maya, jake], at: Venues.bobaGuys)
        await share(plan, with: [oliver, maya, jake])
        let conversation = try await oliver.organize([Self.greenBowl], with: [maya, jake], inputs: [.plan(plan)],
                                                     chainedFrom: plan.origin).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }
        // The card as the app last saved it, before it showed the yes.
        let saved = try #require(await maya.interaction(conversation))

        try await maya.accept(in: conversation)
        #expect(await eventually { await oliver.service.organized[conversation]?.accepted.contains(maya.id) == true })
        await maya.coordinator.add(saved)
        await maya.restart()

        #expect(await maya.reaches(.confirmed, in: conversation))
        await #expect(throws: PickAPlaceError.yesIsFinal) { try await maya.pass(in: conversation) }
        for phone in [jake, oliver] { try await phone.accept(in: conversation) }
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.planned, in: conversation), "\(phone.name)") }
        #expect(await group.lifecyclesWereLegal())
    }

    /// Review of #122: Maya's yes has gone but its ledger write has not
    /// returned. The yes is still on its way, not yet counted: Oliver's
    /// confirmation waits for it rather than being dropped, and a change's
    /// final-yes guard still holds. Retries are a minute apart, so only
    /// the first confirmation can make Maya's card a plan.
    @Test func aYesBeingRecordedIsStillOnItsWay() async throws {
        let slow = PickAPlaceConfiguration(retryInterval: .seconds(60), maxRetryInterval: .seconds(60),
                                           answerWindow: .seconds(30), confirmWindow: .seconds(30))
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all + [Self.greenBowl])
        let ledger = YesWriteHold()
        let oliver = Phone("Oliver", hub: hub, maps: maps, configuration: slow)
        let maya = Phone("Maya", hub: hub, maps: maps, placeLedger: ledger, configuration: slow)
        let jake = Phone("Jake", hub: hub, maps: maps, configuration: slow)
        let group = try await Group([oliver, maya, jake], hub: hub)
        defer { Task { await ledger.open(); await group.stop() } }
        let plan = try dinner([oliver, maya, jake], at: Venues.bobaGuys)
        await share(plan, with: [oliver, maya, jake])
        let conversation = try await oliver.organize([Self.greenBowl], with: [maya, jake], inputs: [.plan(plan)],
                                                     chainedFrom: plan.origin).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }
        try await jake.accept(in: conversation)
        try await oliver.accept(in: conversation)

        let yes = Task { try await maya.accept(in: conversation) }
        #expect(await eventually { await ledger.waiting >= 1 })
        #expect(await oliver.reaches(.planned, in: conversation))
        #expect(await eventually { await maya.service.invites[conversation]?.waitingConfirmation != nil })
        await #expect(throws: PickAPlaceError.yesIsFinal) { try await maya.pass(in: conversation) }

        await ledger.open()
        try await yes.value
        #expect(await maya.reaches(.planned, in: conversation))
        #expect(await group.lifecyclesWereLegal())
    }
}

/// A Pick a place ledger whose yes writes wait for the test, as a slow
/// store would; everything else goes straight through.
actor YesWriteHold: PickAPlaceLedger {
    let base = InMemoryPickAPlaceLedger()
    private var isOpen = false
    private(set) var waiting = 0

    func open() { isOpen = true }

    func recordYes(_ yes: RecordedYes, for conversation: ConversationID) async throws {
        waiting += 1
        while !isOpen { try? await Task.sleep(for: .milliseconds(5)) }
        try await base.recordYes(yes, for: conversation)
    }

    func yes(for conversation: ConversationID) async throws -> RecordedYes? { try await base.yes(for: conversation) }
    func admissions(since date: Date) async throws -> [PeerID: [Date]] { try await base.admissions(since: date) }
    func recordAdmission(_ peer: PeerID, at date: Date) async throws { try await base.recordAdmission(peer, at: date) }
    func pendingWithdrawals() async throws -> [PendingWithdrawal] { try await base.pendingWithdrawals() }
    func recordWithdrawal(_ withdrawal: PendingWithdrawal) async throws { try await base.recordWithdrawal(withdrawal) }
    func clearWithdrawal(_ conversation: ConversationID) async throws { try await base.clearWithdrawal(conversation) }
    func deadlines(for conversation: ConversationID) async throws -> RequestDeadlines? { try await base.deadlines(for: conversation) }
    func recordDeadlines(_ deadlines: RequestDeadlines, for conversation: ConversationID) async throws {
        try await base.recordDeadlines(deadlines, for: conversation)
    }
    func requestKind(for conversation: ConversationID) async throws -> PlaceRequestKind? { try await base.requestKind(for: conversation) }
    func recordRequestKind(_ kind: PlaceRequestKind, for conversation: ConversationID, at date: Date) async throws {
        try await base.recordRequestKind(kind, for: conversation, at: date)
    }
    func acceptedProposals(for conversation: ConversationID) async throws -> [PeerID: MessageID]? {
        try await base.acceptedProposals(for: conversation)
    }
    func recordAcceptedProposals(_ proposals: [PeerID: MessageID], for conversation: ConversationID, at date: Date) async throws {
        try await base.recordAcceptedProposals(proposals, for: conversation, at: date)
    }
}
