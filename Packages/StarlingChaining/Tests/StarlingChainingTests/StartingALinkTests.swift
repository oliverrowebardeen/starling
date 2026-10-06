import Foundation
import StarlingChaining
import StarlingCore
import StarlingFakes
import Testing

@Suite struct StartingALinkTests {
    let planner = ChainPlanner(registry: SampleSkills.registry, me: Fixtures.me)
    let settings = SkillSettings(flags: .phase1_5)
    let swapOn = SkillSettings(flags: Fixtures.flagsWithSwapPhotos)
    let tap = OwnerTap(at: Fixtures.at(minutes: 6))
    let expiry = Fixtures.at(minutes: 90)

    func row(_ skill: SkillID, after plan: Interaction, in interactions: [Interaction]? = nil, settings: SkillSettings? = nil) throws -> ChainSuggestion {
        try #require(planner.suggestions(after: plan.id, in: interactions ?? [plan], settings: settings ?? self.settings, cards: Fixtures.cards()).first { $0.id == skill })
    }

    @Test func aLinkThatAddsATopicWaitsForTheOwnersConsent() throws {
        let plan = try Fixtures.plannedDownFor()
        let row = try row(.pickAPlace, after: plan)
        #expect(throws: ChainError.consentRequired(row.adds)) {
            try planner.begin(row, in: [plan], settings: settings, cards: Fixtures.cards(), tap: tap, consent: nil, rules: .empty, expiresAt: expiry)
        }
        // Consent for another plan, or another skill, does not count.
        let elsewhere = LinkConsent(parent: InteractionID(), skill: row.skill.ref, approved: row.adds, at: tap.at)
        #expect(throws: ChainError.consentRequired(row.adds)) {
            try planner.begin(row, in: [plan], settings: settings, cards: Fixtures.cards(), tap: tap, consent: elsewhere, rules: .empty, expiresAt: expiry)
        }
        // Approving only part of what it adds does not count either.
        let partial = LinkConsent(parent: plan.id, skill: row.skill.ref, approved: SkillExposure(topics: [.diet]), at: tap.at)
        #expect(throws: ChainError.consentRequired(row.adds)) {
            try planner.begin(row, in: [plan], settings: settings, cards: Fixtures.cards(), tap: tap, consent: partial, rules: .empty, expiresAt: expiry)
        }
    }

    @Test func aConsentedTapStartsALinkThatRecordsTheTapAndCarriesChainedFrom() throws {
        let plan = try Fixtures.plannedDownFor()
        let row = try row(.pickAPlace, after: plan)
        let start = try planner.begin(row, in: [plan], settings: settings, cards: Fixtures.cards(), tap: tap,
                                      consent: row.consent(approvedAt: tap.at), rules: .empty, expiresAt: expiry)
        let link = start.interaction
        #expect(link.state == .drafting)
        #expect(link.role == .initiator)
        #expect(link.skill == SampleSkills.pickAPlace.ref)
        #expect(link.participants == [Fixtures.maya, Fixtures.jake])
        #expect(link.chain == ChainLink(parent: plan.id, parentConversation: plan.conversation, consumed: [.plan], trigger: .atConfirm, optedInAt: tap.at))
        #expect(link.createdAt == tap.at)

        let request = start.request
        #expect(request.interaction == link.id)
        #expect(request.conversation == link.conversation)
        #expect(request.conversation != plan.conversation)
        #expect(request.chainedFrom == plan.conversation)
        #expect(request.inputs == [.plan(try #require(plan.plan))])
        #expect(request.participants == [Fixtures.maya, Fixtures.jake])
        #expect(request.intent.audience == .picked([Fixtures.maya, Fixtures.jake]))
        #expect(request.intent.skill == SampleSkills.pickAPlace.ref)
        #expect(request.intent.expiresAt == expiry)
        // The chain the timeline shows now runs from the plan to the link.
        #expect([plan, link].chain(from: plan.id).map(\.id) == [plan.id, link.id])
    }

    @Test func aLinkThatAddsNothingStartsOnTheTapAlone() throws {
        let plan = try Fixtures.plannedDownFor()
        let earlier = try KeepItGoingTests.link(after: plan, reaching: KeepItGoingTests.agreed())
        let row = try row(.pickAPlace, after: plan, in: [plan, earlier])
        #expect(!row.needsConsent)
        let start = try planner.begin(row, in: [plan, earlier], settings: settings, cards: Fixtures.cards(), tap: tap, consent: nil, rules: .empty, expiresAt: expiry)
        #expect(start.interaction.chain?.optedInAt == tap.at)
    }

    @Test func theRowIsCheckedAgainAtTheTap() throws {
        let plan = try Fixtures.plannedDownFor()
        let row = try row(.pickAPlace, after: plan)
        // Jake's card changed after the row was drawn.
        var cards = Fixtures.cards()
        cards[Fixtures.jake] = Fixtures.card([SampleSkills.downFor])
        #expect(throws: ChainError.notOffered(.pickAPlace)) {
            try planner.begin(row, in: [plan], settings: settings, cards: cards, tap: tap, consent: row.consent(approvedAt: tap.at), rules: .empty, expiresAt: expiry)
        }
        // The owner switched the skill off.
        #expect(throws: ChainError.notOffered(.pickAPlace)) {
            try planner.begin(row, in: [plan], settings: SkillSettings(flags: .phase1_5, turnedOff: [.pickAPlace]), cards: Fixtures.cards(), tap: tap,
                              consent: row.consent(approvedAt: tap.at), rules: .empty, expiresAt: expiry)
        }
    }

    @Test func consentIsCheckedAgainstWhatTheLinkAddsNow() throws {
        let plan = try Fixtures.plannedDownFor()
        let earlier = try KeepItGoingTests.link(after: plan, reaching: KeepItGoingTests.agreed())
        // Drawn when the earlier link had granted everything: no consent.
        let stale = try row(.pickAPlace, after: plan, in: [plan, earlier])
        #expect(!stale.needsConsent)
        // Without that link the row adds location, diet, and location access again, so the
        // tap alone is not enough.
        #expect(throws: ChainError.consentRequired(SkillExposure(topics: [.location, .diet], permissions: [.locationWhenInUse]))) {
            try planner.begin(stale, in: [plan], settings: settings, cards: Fixtures.cards(), tap: tap, consent: nil, rules: .empty, expiresAt: expiry)
        }
    }

    @Test func atConfirmAndAfterPlanEndsCannotBeSwapped() throws {
        let plan = try Fixtures.plannedDownFor()
        let place = try row(.pickAPlace, after: plan, settings: swapOn)
        let photos = try row(.swapPhotos, after: plan, settings: swapOn)
        #expect(throws: ChainError.wrongTrigger(.atConfirm)) {
            try planner.optIn(place, in: [plan], settings: swapOn, cards: Fixtures.cards(), tap: tap, consent: place.consent(approvedAt: tap.at))
        }
        #expect(throws: ChainError.wrongTrigger(.afterPlanEnds)) {
            try planner.begin(photos, in: [plan], settings: swapOn, cards: Fixtures.cards(), tap: tap, consent: photos.consent(approvedAt: tap.at),
                              rules: .empty, expiresAt: expiry)
        }
    }

    @Test func optingIntoSwapPhotosAfterRecordsTheOptInAndWaits() throws {
        let plan = try Fixtures.plannedDownFor()
        let row = try row(.swapPhotos, after: plan, settings: swapOn)
        #expect(throws: ChainError.consentRequired(SkillExposure(topics: [.photos], permissions: [.photoLibrary]))) {
            try planner.optIn(row, in: [plan], settings: swapOn, cards: Fixtures.cards(), tap: tap, consent: nil)
        }
        let waiting = try planner.optIn(row, in: [plan], settings: swapOn, cards: Fixtures.cards(), tap: tap, consent: row.consent(approvedAt: tap.at))
        #expect(waiting.state == .drafting)
        #expect(waiting.chain == ChainLink(parent: plan.id, parentConversation: plan.conversation, consumed: [.plan], trigger: .afterPlanEnds, optedInAt: tap.at))
        #expect(ChainPlanner.isWaitingForPlanEnd(waiting))

        // The switch now shows on, and a second opt-in is refused.
        let again = try self.row(.swapPhotos, after: plan, in: [plan, waiting], settings: swapOn)
        #expect(again.scheduled == waiting.id)
        #expect(throws: ChainError.alreadyScheduled(waiting.id)) {
            try planner.optIn(again, in: [plan, waiting], settings: swapOn, cards: Fixtures.cards(), tap: tap, consent: again.consent(approvedAt: tap.at))
        }
        #expect(try planner.optOut(waiting, tap: tap) == waiting.id)
    }

    @Test func onlyAWaitingLinkCanBeOptedOutOf() throws {
        let plan = try Fixtures.plannedDownFor()
        #expect(throws: ChainError.notScheduled(plan.id)) { try planner.optOut(plan, tap: tap) }
        var started = try planner.optIn(try row(.swapPhotos, after: plan, settings: swapOn), in: [plan], settings: swapOn, cards: Fixtures.cards(), tap: tap,
                                        consent: try row(.swapPhotos, after: plan, settings: swapOn).consent(approvedAt: tap.at))
        try started.apply(.started, at: Fixtures.at(minutes: 220))
        #expect(throws: ChainError.notScheduled(started.id)) { try planner.optOut(started, tap: tap) }
    }

    /// The plan a place link agrees for `parent`: the next revision, as
    /// Pick a place puts it on every phone's proposal (#118).
    static func agreedPlan(_ parent: Interaction, place: PlaceChoice = Fixtures.place("Boba Guys on Franklin"), roster: [PeerID]? = nil) throws -> Plan {
        let plan = try #require(parent.plan)
        return try plan.updating(attendees: roster.map { try Attendees($0) } ?? plan.attendees, place: .some(place))
    }

    /// This phone's place link for `parent`, planned, its artifacts not yet in.
    static func ownLink(after parent: Interaction, roster: [PeerID]? = nil) throws -> Interaction {
        try KeepItGoingTests.link(after: parent, reaching: KeepItGoingTests.agreed(plan: agreedPlan(parent, roster: roster)))
    }

    /// A friend's place request on Maya's phone, grouped under `parent`.
    static func friendsLink(under parent: Interaction, roster: [PeerID]) throws -> Interaction {
        var link = Interaction(skill: SampleSkills.pickAPlace.ref, role: .invitee, participants: [Fixtures.jake], createdAt: Fixtures.at(minutes: 9))
        try link.setFriendChainHint(parent.planConversation)
        for event in [InteractionEvent.proposalReady(SkillProposal(revision: 1, participants: roster,
                                                                   terms: try Terms([.place: .places([Fixtures.place()])]),
                                                                   plan: try agreedPlan(parent, place: Fixtures.place()))),
                      .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try link.apply(event, at: Fixtures.at(minutes: 10))
        }
        return link
    }

    @Test func aFinishedPickAPlaceLinkMovesThePlan() throws {
        let plan = try Fixtures.plannedDownFor()
        var link = try Self.ownLink(after: plan)
        #expect(planner.parent(plan, updatedBy: link) == nil)
        link.record(.placeChoice(Fixtures.place("Boba Guys on Franklin")))
        link.record(.attendees(try #require(plan.plan).attendees))
        let updated = try #require(planner.parent(plan, updatedBy: link))
        #expect(updated.plan?.place == Fixtures.place("Boba Guys on Franklin"))
        #expect(updated.plan?.id == plan.plan?.id)
        #expect(updated.plan?.time == plan.plan?.time)
        // A link of another plan never moves this one.
        let other = try Fixtures.plannedDownFor()
        #expect(planner.parent(other, updatedBy: link) == nil)
    }

    @Test func thisPhonesPlaceLinkNarrowsThePlanToThoseWhoAccepted() throws {
        // Issue #66: this phone organized the place; Jake passed, Maya and
        // you accepted. The plan takes the place and its people, once.
        let plan = try Fixtures.plannedDownFor()
        var link = try Self.ownLink(after: plan, roster: [Fixtures.me, Fixtures.maya])
        link.record(.placeChoice(Fixtures.place("Boba Guys on Franklin")))
        link.record(.attendees(try Attendees([Fixtures.maya, Fixtures.me])))
        let updated = try #require(planner.parent(plan, updatedBy: link))
        #expect(updated.plan?.attendees.peers == [Fixtures.me, Fixtures.maya])
        #expect(updated.plan?.place == Fixtures.place("Boba Guys on Franklin"))
        #expect(updated.plan?.revision == 1)
        #expect(planner.parent(updated, updatedBy: link) == nil)
        // The next chain goes only to Maya.
        let row = try #require(planner.suggestions(after: updated.id, in: [updated, link], settings: SkillSettings(flags: Fixtures.flagsWithSwapPhotos),
                                                   cards: Fixtures.cards()).first { $0.id == .swapPhotos })
        #expect(row.participants == [Fixtures.maya])
        // A roster with someone the plan never had, or without this phone, changes nothing.
        for roster in [[Fixtures.me, Fixtures.maya, Fixtures.stranger], [Fixtures.maya, Fixtures.jake]] {
            link.record(.attendees(try Attendees(roster)))
            #expect(planner.parent(plan, updatedBy: link) == nil)
        }
    }

    @Test func aFriendsPlaceLinkNeedsTheWholePlanAndRemovesNobody() throws {
        // Review of PR #111, finding D: Jake organized a place, Maya accepted,
        // and this phone's owner did not. A friend's link, grouped under the
        // plan, is not authority to narrow it.
        let plan = try Fixtures.plannedDownFor(role: .invitee)
        var fromJake = try Self.friendsLink(under: plan, roster: [Fixtures.jake, Fixtures.maya])
        fromJake.record(.placeChoice(Fixtures.place()))
        fromJake.record(.attendees(try Attendees([Fixtures.jake, Fixtures.maya])))
        #expect(planner.parent(plan, updatedBy: fromJake) == nil)
    }

    @Test func aPlaceEveryoneAgreedAppliesOnceInAnyRosterOrder() throws {
        let plan = try Fixtures.plannedDownFor()
        var link = try Self.ownLink(after: plan)
        link.record(.placeChoice(Fixtures.place("Boba Guys on Franklin")))
        // The organizer first: the same people, in another order.
        link.record(.attendees(try Attendees([Fixtures.maya, Fixtures.me, Fixtures.jake])))
        let updated = try #require(planner.parent(plan, updatedBy: link))
        #expect(updated.plan?.place == Fixtures.place("Boba Guys on Franklin"))
        #expect(updated.plan?.attendees == plan.plan?.attendees)
        #expect(updated.plan?.revision == 1)
        // Once: not again, whatever arrives later.
        #expect(planner.parent(updated, updatedBy: link) == nil)
    }

    /// Review of PR #111, finding 5, and the review of #118: a place result
    /// applies only over the revision just before the one it names.
    @Test func aPlaceResultAppliesOnlyAtThePlansNextRevision() throws {
        let plan = try Fixtures.plannedDownFor()
        let moved = try Self.movedTo(revision: 1, plan)
        // Agreed over revision 0, arriving once the plan is at 1: ignored, so
        // revision 2 is never reused for it.
        var stale = try Self.ownLink(after: plan)
        stale.record(.placeChoice(Fixtures.place("Boba Guys on Franklin")))
        stale.record(.attendees(try #require(plan.plan).attendees))
        #expect(planner.parent(moved, updatedBy: stale) == nil)
        // Agreed over revision 1: applies, keeping the revision it names.
        var fresh = try Self.ownLink(after: moved)
        fresh.record(.placeChoice(Fixtures.place("Boba Guys on Franklin")))
        fresh.record(.attendees(try #require(moved.plan).attendees))
        let updated = try #require(planner.parent(moved, updatedBy: fresh))
        #expect(updated.plan?.revision == 2)
        // A result naming a revision past the next is not applied either.
        #expect(planner.parent(plan, updatedBy: fresh) == nil)
    }

    /// Issue #119 (PC37): a friend was added after a place step was asked;
    /// the step's result arrives late and cannot take them out.
    @Test func aStalePlaceResultCannotRemoveSomeoneAddedSince() throws {
        let plan = try Fixtures.plannedDownFor()
        var stale = try Self.ownLink(after: plan, roster: [Fixtures.me, Fixtures.maya])
        stale.record(.placeChoice(Fixtures.place("Boba Guys on Franklin")))
        stale.record(.attendees(try Attendees([Fixtures.me, Fixtures.maya])))
        var added = plan
        added.record(.plan(try #require(plan.plan).updating(attendees: Attendees([Fixtures.me, Fixtures.maya, Fixtures.jake, Fixtures.stranger]))))
        #expect(planner.parent(added, updatedBy: stale) == nil)
    }

    /// Review of PR #111, finding 6, and issue #119 (PC38): the coordinator
    /// applies each event as it comes and asks for the parent after each.
    /// Place and roster arrive one at a time, in either order, and a
    /// shortened roster may follow; the plan moves exactly once.
    @Test(arguments: [false, true])
    func aPlaceResultDeliveredOneArtifactAtATimeMovesThePlanOnce(placeFirst: Bool) throws {
        var parent = try Fixtures.plannedDownFor()
        let original = try #require(parent.plan)
        let place = Fixtures.place("Boba Guys on Franklin")
        let roster = try Attendees([Fixtures.me, Fixtures.maya])
        var link = Interaction(
            skill: SampleSkills.pickAPlace.ref, role: .initiator, participants: [Fixtures.maya, Fixtures.jake], createdAt: Fixtures.at(minutes: 10),
            chain: ChainLink(parent: parent.id, parentConversation: parent.conversation, consumed: [.plan], trigger: .atConfirm,
                             optedInAt: Fixtures.at(minutes: 10))
        )
        let produced: [Artifact] = placeFirst ? [.placeChoice(place), .attendees(roster)] : [.attendees(roster), .placeChoice(place)]
        let events: [SkillEvent] = try KeepItGoingTests.agreed(plan: Self.agreedPlan(parent, place: place, roster: roster.peers))
            .map { SkillEvent.lifecycle(link.id, $0) }
            + produced.map { SkillEvent.produced(link.id, $0) }
            + [.produced(link.id, .attendees(try Attendees([Fixtures.me, Fixtures.maya])))]
        var revisions: [UInt32] = []
        for (minute, event) in events.enumerated() {
            switch event {
            case .lifecycle(_, let lifecycle): try link.apply(lifecycle, at: Fixtures.at(minutes: 11 + minute))
            case .produced(_, let artifact): link.record(artifact)
            case .incoming: break
            }
            if let updated = planner.parent(parent, updatedBy: link) {
                parent = updated
                revisions.append(try #require(updated.plan).revision)
            }
        }
        #expect(revisions == [1])
        #expect(parent.plan?.place == place)
        #expect(parent.plan?.attendees == roster)
        #expect(parent.plan?.id == original.id)
    }

    @Test func aFriendsPlaceRequestUpdatesThePlanOnThisPhoneToo() throws {
        // On Maya's phone: Jake's agent asked to pick a place for the plan.
        let plan = try Fixtures.plannedDownFor(role: .invitee)
        var fromJake = try Self.friendsLink(under: plan, roster: [Fixtures.me, Fixtures.maya, Fixtures.jake])
        fromJake.record(.placeChoice(Fixtures.place()))
        // A friend's request changes nothing until it names its roster, and
        // then only if that is the whole plan (review of PR #111, finding D).
        #expect(planner.parent(plan, updatedBy: fromJake) == nil)
        fromJake.record(.attendees(try Attendees([Fixtures.jake, Fixtures.me, Fixtures.maya])))
        let updated = try #require(planner.parent(plan, updatedBy: fromJake))
        #expect(updated.plan?.place == Fixtures.place())
        #expect(updated.plan?.revision == 1)
        // A friend's request for another plan does not.
        let other = try Fixtures.plannedDownFor(role: .invitee)
        #expect(planner.parent(other, updatedBy: fromJake) == nil)
    }

    /// `parent` with its plan moved to `revision` by another change.
    static func movedTo(revision: UInt32, _ parent: Interaction) throws -> Interaction {
        var moved = parent
        var plan = try #require(parent.plan)
        while plan.revision < revision { plan = try plan.updating(activity: .some(try Keyword("dinner"))) }
        moved.record(.plan(plan))
        return moved
    }
}
