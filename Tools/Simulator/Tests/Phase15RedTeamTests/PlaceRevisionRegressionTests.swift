import Foundation
import StarlingChaining
import StarlingCore
import Testing

struct PlaceRevisionRegressionTests {
    private func finishedLink(_ parent: Interaction, agreeing roster: Attendees, place: PlaceChoice) throws -> Interaction {
        let planner = ChainPlanner(registry: ChainFixture.registry, me: P15.alice)
        let cards = try ChainFixture.cards(#require(parent.plan).attendees.peers.filter { $0 != P15.alice })
        let row = try #require(planner.suggestions(after: parent.id, in: [parent], settings: ChainFixture.settings, cards: cards)
            .first { $0.id == .pickAPlace })
        var link = try planner.begin(row, in: [parent], settings: ChainFixture.settings, cards: cards,
            tap: OwnerTap(at: P15.now), consent: row.consent(approvedAt: P15.now), rules: .empty,
            expiresAt: Timestamp(P15.date.addingTimeInterval(300))).interaction
        try link.apply(.started, at: P15.now)
        let plan = try #require(parent.plan).updating(attendees: roster, place: .some(place))
        var values: [IssueKey: IssueValue] = [.place: .places([place]), .people: .peers(roster.peers)]
        if let time = plan.time { values[.time] = .slots([time]) }
        if let activity = plan.activity { values[.activity] = .keywords([activity]) }
        try link.apply(.proposalReady(SkillProposal(revision: 1, participants: roster.peers,
            terms: Terms(values), plan: plan)), at: P15.now)
        try link.apply(.ownerAccepted(revision: 1), at: P15.now)
        try link.apply(.everyoneConfirmed(revision: 1), at: P15.now)
        return link
    }

    /// These are real ChainPlanner boundary tests. Prepared result artifacts
    /// isolate coordinator delivery order from Pick a place's negotiation.
    /// The proposal carries the agreed next-revision plan (ADR 0022); running
    /// D's producer against E's updater remains a separate integration case.
    @Test func pc37AStalePlaceResultCannotRemoveANewlyAddedFriend() throws {
        let original = try ChainFixture.parent(me: P15.alice, attendees: [P15.alice, P15.bob])
        let planner = ChainPlanner(registry: ChainFixture.registry, me: P15.alice)
        let place = try PlaceWorld.candidate().choice
        var stale = try finishedLink(original, agreeing: Attendees([P15.alice, P15.bob]), place: place)
        stale.record(.placeChoice(place))
        stale.record(.attendees(try Attendees([P15.alice, P15.bob])))
        var current = original
        current.record(.plan(try #require(original.plan).updating(attendees: Attendees([P15.alice, P15.bob, P15.eve]))))
        #expect(current.plan?.revision == 1)
        #expect(planner.parent(current, updatedBy: stale) == nil)
        // A fresh owner link that asked the new roster may still narrow it.
        var fresh = try finishedLink(current, agreeing: Attendees([P15.alice, P15.bob]), place: place)
        fresh.record(.placeChoice(place))
        fresh.record(.attendees(try Attendees([P15.alice, P15.bob])))
        let updated = try #require(planner.parent(current, updatedBy: fresh))
        #expect(updated.plan?.revision == 2)
        #expect(updated.plan?.attendees.peers == [P15.alice, P15.bob])
        #expect(updated.plan?.place == place)
    }

    @Test(arguments: [false, true])
    func pc38SplitPlaceAndRosterArtifactsCommitOneRevision(placeFirst: Bool) throws {
        let original = try ChainFixture.parent(me: P15.alice, attendees: [P15.alice, P15.bob, P15.eve])
        let planner = ChainPlanner(registry: ChainFixture.registry, me: P15.alice)
        let place = try PlaceWorld.candidate().choice
        let roster = try Attendees([P15.alice, P15.bob])
        var link = try finishedLink(original, agreeing: roster, place: place)
        let artifacts: [Artifact] = placeFirst ? [.placeChoice(place), .attendees(roster)] : [.attendees(roster), .placeChoice(place)]
        var current = original
        for artifact in artifacts {
            link.record(artifact)
            if let update = planner.parent(current, updatedBy: link) { current = update }
        }
        #expect(current.plan?.revision == 1)
        #expect(current.plan?.place == place)
        #expect(current.plan?.attendees == roster)
        #expect(planner.parent(current, updatedBy: link) == nil)
    }
}
