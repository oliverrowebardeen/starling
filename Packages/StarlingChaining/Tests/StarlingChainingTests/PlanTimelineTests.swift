import Foundation
import StarlingChaining
import StarlingCore
import StarlingFakes
import Testing

@Suite struct PlanTimelineTests {
    let registry = SampleSkills.registry
    let planner = ChainPlanner(registry: SampleSkills.registry, me: Fixtures.me)

    static func record(_ minute: Int, to peer: PeerID, _ items: [(IssueKey, IssueValue?)], category: DisclosedItem.Category = .terms) -> EgressRecord {
        EgressRecord(at: Fixtures.at(minutes: minute), recipient: peer, items: items.map { DisclosedItem(category: category, issue: $0.0, value: $0.1) })
    }

    /// The plan detail mockup: Down for… boba, then Pick a place, then Swap
    /// photos waiting for the plan to end.
    func boba() throws -> (plan: Interaction, place: Interaction, photos: Interaction) {
        var plan = try Fixtures.plannedDownFor()
        for friend in [Fixtures.maya, Fixtures.jake] {
            plan.record(Self.record(1, to: friend, [(.activity, .keywords([Fixtures.boba])), (.time, .slots([Fixtures.tonight]))]))
        }
        var place = try KeepItGoingTests.link(after: plan, reaching: KeepItGoingTests.agreed(), at: 8)
        place.record(Self.record(9, to: Fixtures.maya, [(.place, .places([Fixtures.place()]))]))
        place.record(Self.record(9, to: Fixtures.jake, [(.place, .places([Fixtures.place()]))]))
        place.record(.placeChoice(Fixtures.place()))
        let photos = Interaction(skill: SampleSkills.swapPhotos.ref, role: .initiator, participants: [Fixtures.maya, Fixtures.jake],
                                 createdAt: Fixtures.at(minutes: 14),
                                 chain: ChainLink(parent: plan.id, parentConversation: plan.conversation, consumed: [.plan], trigger: .afterPlanEnds,
                                                  optedInAt: Fixtures.at(minutes: 14)))
        return (plan, place, photos)
    }

    @Test func howThisCameTogetherListsThePlanAndItsLinksInOrder() throws {
        let (plan, place, photos) = try boba()
        let unrelated = try Fixtures.plannedDownFor()
        let timeline = try #require(PlanTimeline(for: plan.id, in: [photos, unrelated, place, plan], registry: registry))
        #expect(timeline.root == plan.id)
        #expect(timeline.entries.map(\.id) == [plan.id, place.id, photos.id])
        #expect(timeline.entries.map(\.name) == ["Down for…", "Pick a place", "Swap photos"])
        #expect(timeline.entries.map(\.origin) == [.plan, .chained(.atConfirm, optedInAt: Fixtures.at(minutes: 8)),
                                                   .chained(.afterPlanEnds, optedInAt: Fixtures.at(minutes: 14))])
        #expect(timeline.entries.map(\.state) == [.planned, .planned, .drafting])
        #expect(timeline.entries.map(\.startsAfter) == [nil, nil, Fixtures.tonight.end])
        #expect(timeline.entries[1].artifacts == [.placeChoice(Fixtures.place())])
        // Opened from any link, it is the same plan's timeline.
        #expect(PlanTimeline(for: place.id, in: [plan, place, photos], registry: registry) == timeline)
        #expect(PlanTimeline(for: InteractionID(), in: [plan], registry: registry) == nil)
    }

    @Test func whatLeftYourPhoneSplitsSharedFromKeptByTopic() throws {
        let (plan, place, photos) = try boba()
        let whatLeft = try #require(PlanTimeline(for: plan.id, in: [plan, place, photos], registry: registry)).whatLeft
        #expect(whatLeft.shared.map(\.topic) == [.time, .activity, .place])
        #expect(whatLeft.shared.map(\.values) == [[.slots([Fixtures.tonight])], [.keywords([Fixtures.boba])], [.places([Fixtures.place()])]])
        #expect(whatLeft.shared.allSatisfy { $0.recipients == [Fixtures.maya, Fixtures.jake] && $0.sends == 2 })
        // Where you are, budget, diet, and photos are used by the plan's skills
        // but never left; location access and the photo library stayed too.
        #expect(whatLeft.kept == [.topic(.location), .topic(.budget), .topic(.diet), .topic(.photos), .permission(.locationWhenInUse), .permission(.photoLibrary)])
        #expect(whatLeft.other.isEmpty)
        #expect(whatLeft.sends == 4)
    }

    @Test func aLinkWhoseLogIsUnconfirmedIsNotVouchedFor() throws {
        let (plan, place, photos) = try boba()
        let timeline = try #require(PlanTimeline(for: plan.id, in: [plan, place, photos], registry: registry, unconfirmed: [place.conversation]))
        #expect(timeline.whatLeft.unconfirmed == [place.id])
        // Pick a place uses place, where you are, budget, diet, and location
        // access: none of them is claimed as kept while its log may be
        // missing a send. Swap photos has not run and its log is complete,
        // so photos still is.
        #expect(timeline.whatLeft.kept == [.topic(.photos), .permission(.photoLibrary)])
        // What its log does show is still listed as shared.
        #expect(timeline.whatLeft.shared.map(\.topic) == [.time, .activity, .place])
    }

    @Test func thePlansWhatLeftIsExactlyItsEgressLogs() throws {
        let (plan, place, photos) = try boba()
        let whatLeft = try #require(PlanTimeline(for: plan.id, in: [plan, place, photos], registry: registry)).whatLeft
        let logged = [plan, place].flatMap(\.egress).flatMap(\.items)
        let listed = whatLeft.shared.flatMap { shared in shared.values.map { (shared.topic, $0) } }
        for item in logged {
            let topic = try #require(item.issue.flatMap(PrivacyTopic.init(issue:)))
            #expect(listed.contains { $0.0 == topic && $0.1 == item.value })
        }
        #expect(listed.count == Set(logged.compactMap(\.value)).count)
    }

    @Test func aPrivateCheckAndTheAgentCardShowWithoutValues() throws {
        var plan = try Fixtures.plannedDownFor()
        plan.record(Self.record(1, to: Fixtures.maya, [(.time, nil)], category: .psi))
        plan.record(EgressRecord(at: Fixtures.at(minutes: 1), recipient: Fixtures.maya, items: [DisclosedItem(category: .agentCard, issue: nil, value: nil)]))
        plan.record(EgressRecord(at: Fixtures.at(minutes: 2), recipient: Fixtures.maya, items: []))
        let whatLeft = WhatLeftYourPhone(interactions: [plan], registry: registry)
        #expect(whatLeft.shared.map(\.topic) == [.time])
        #expect(whatLeft.shared.first?.values == [])
        #expect(whatLeft.other == [DisclosedItem(category: .agentCard, issue: nil, value: nil)])
        #expect(whatLeft.sends == 3)
    }

    @Test func aFriendsChainedRequestIsGroupedButMarkedAsTheirs() throws {
        // On Maya's phone: she was asked, and then Jake's agent asked to
        // pick a place for the same plan.
        let plan = try Fixtures.plannedDownFor(role: .invitee)
        var fromJake = Interaction(skill: SampleSkills.pickAPlace.ref, role: .invitee, participants: [Fixtures.jake], createdAt: Fixtures.at(minutes: 9))
        #expect(PlanTimeline(for: fromJake.id, in: [plan, fromJake], registry: registry)?.entries.map(\.id) == [fromJake.id])

        // The coordinator keeps the hint once IncomingChain accepts it.
        try fromJake.setFriendChainHint(IncomingChain.timelineParent(chainedFrom: plan.conversation, sender: Fixtures.jake, interactions: [plan]))
        let timeline = try #require(PlanTimeline(for: fromJake.id, in: [plan, fromJake], registry: registry))
        #expect(timeline.root == plan.id)
        #expect(timeline.entries.map(\.origin) == [.plan, .friend])
        #expect(fromJake.chain == nil)
    }

    @Test func aHintTheCoordinatorRejectedGroupsNothing() throws {
        let plan = try Fixtures.plannedDownFor(role: .invitee)
        var fromStranger = Interaction(skill: SampleSkills.pickAPlace.ref, role: .invitee, participants: [Fixtures.stranger], createdAt: Fixtures.at(minutes: 9))
        // Not in the plan: no hint to keep, so it stands alone.
        try fromStranger.setFriendChainHint(IncomingChain.timelineParent(chainedFrom: plan.conversation, sender: Fixtures.stranger, interactions: [plan]))
        #expect(fromStranger.friendChainHint == nil)
        #expect(PlanTimeline(for: fromStranger.id, in: [plan, fromStranger], registry: registry)?.entries.map(\.id) == [fromStranger.id])
        // And the owner's own interactions can never carry one.
        var mine = try Fixtures.plannedDownFor()
        #expect(throws: ValidationError.self) { try mine.setFriendChainHint(plan.conversation) }
    }
}
