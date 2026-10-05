import Foundation
import StarlingChaining
import StarlingCore
import StarlingFakes
import Testing

@Suite struct KeepItGoingTests {
    let planner = ChainPlanner(registry: SampleSkills.registry, me: Fixtures.me)
    let settings = SkillSettings(flags: .phase1_5)

    /// A Pick a place link chained after `parent`, driven to `states`.
    static func link(after parent: Interaction, skill: SkillDescriptor = SampleSkills.pickAPlace, reaching events: [InteractionEvent], at minute: Int = 10) throws -> Interaction {
        var link = Interaction(
            skill: skill.ref, role: .initiator, participants: [Fixtures.maya, Fixtures.jake], createdAt: Fixtures.at(minutes: minute),
            chain: ChainLink(parent: parent.id, parentConversation: parent.conversation, consumed: [.plan], trigger: skill.chainTrigger,
                             optedInAt: Fixtures.at(minutes: minute))
        )
        for (offset, event) in events.enumerated() { try link.apply(event, at: Fixtures.at(minutes: minute + offset + 1)) }
        return link
    }

    /// A place link's events up to "It's a plan", with `plan` as the agreed
    /// plan each phone's proposal carries (#118).
    static func agreed(_ revision: UInt32 = 1, plan: Plan? = nil) throws -> [InteractionEvent] {
        let terms = try Terms([.place: .places([Fixtures.place()])])
        return [.started, .proposalReady(SkillProposal(revision: revision, participants: [Fixtures.me, Fixtures.maya, Fixtures.jake], terms: terms,
                                                       plan: plan)),
                .ownerAccepted(revision: revision), .everyoneConfirmed(revision: revision)]
    }

    @Test func downForSuggestsPickAPlaceWithAFreshConsentForWhatItAdds() throws {
        let plan = try Fixtures.plannedDownFor()
        let rows = planner.suggestions(after: plan.id, in: [plan], settings: settings, cards: Fixtures.cards())
        #expect(rows.map(\.id) == [.pickAPlace])
        let row = try #require(rows.first)
        #expect(row.consumes == [.plan])
        #expect(row.participants == [Fixtures.maya, Fixtures.jake])
        #expect(row.parentConversation == plan.conversation)
        #expect(row.trigger == .atConfirm)
        // Down for… already covers time, activity, place, and budget; Pick a
        // place adds where you are and diet (ADR 0019), and location access.
        #expect(row.adds == SkillExposure(topics: [.location, .diet], permissions: [.locationWhenInUse]))
        #expect(row.needsConsent)
    }

    @Test func aLinkThatAddsNothingNeedsNoFreshConsent() throws {
        let placesOnly = try SkillDescriptor(
            ref: SampleSkills.pickAPlace.ref, wording: SampleSkills.pickAPlace.wording, buildingBlock: .privateAggregation,
            topicsUsed: [.place, .budget], topicsRequired: [.place], accepts: [.plan], produces: [.placeChoice],
            intent: IntentSchema(slots: [IntentSlot(.place, required: false, hint: "the area")])
        )
        let planner = ChainPlanner(registry: try SkillRegistry([SampleSkills.downFor, placesOnly]), me: Fixtures.me)
        let plan = try Fixtures.plannedDownFor()
        let row = try #require(planner.suggestions(after: plan.id, in: [plan], settings: settings, cards: Fixtures.cards([SampleSkills.downFor, placesOnly])).first)
        #expect(row.adds.isEmpty)
        #expect(!row.needsConsent)
    }

    @Test func unsupportedChainsAreHiddenNotShownAndFailed() throws {
        let plan = try Fixtures.plannedDownFor()
        var cards = Fixtures.cards()
        // Jake's Starling does not do Pick a place.
        cards[Fixtures.jake] = Fixtures.card([SampleSkills.downFor])
        #expect(planner.suggestions(after: plan.id, in: [plan], settings: settings, cards: cards).isEmpty)
        // Jake runs a different major version.
        let newer = try SkillDescriptor(
            ref: SkillRef(.pickAPlace, SkillVersion(2)), wording: SampleSkills.pickAPlace.wording, buildingBlock: .privateAggregation,
            topicsUsed: [.place], topicsRequired: [.place], accepts: [.plan], produces: [.placeChoice],
            intent: IntentSchema(slots: [IntentSlot(.place, required: false, hint: "the area")])
        )
        cards[Fixtures.jake] = Fixtures.card([SampleSkills.downFor, newer])
        #expect(planner.suggestions(after: plan.id, in: [plan], settings: settings, cards: cards).isEmpty)
        // This phone does not know Jake's card at all.
        cards[Fixtures.jake] = nil
        #expect(planner.suggestions(after: plan.id, in: [plan], settings: settings, cards: cards).isEmpty)
    }

    @Test func onlyAPlanCanBeKeptGoing() throws {
        var proposed = Interaction(skill: SampleSkills.downFor.ref, role: .invitee, participants: [Fixtures.maya], createdAt: Fixtures.at(minutes: 0))
        let terms = try Terms([.activity: .keywords([Fixtures.boba])])
        try proposed.apply(.proposalReady(SkillProposal(revision: 1, participants: [Fixtures.me, Fixtures.maya], terms: terms)), at: Fixtures.at(minutes: 1))
        #expect(planner.suggestions(after: proposed.id, in: [proposed], settings: settings, cards: Fixtures.cards()).isEmpty)
        #expect(planner.suggestions(after: InteractionID(), in: [proposed], settings: settings, cards: Fixtures.cards()).isEmpty)
    }

    @Test func aRowNeedsSomethingThePlanActuallyProduced() throws {
        var plan = try Fixtures.plannedDownFor()
        plan = Interaction(skill: plan.skill, role: .invitee, participants: plan.participants, createdAt: plan.createdAt)
        // Planned, but no plan artifact recorded yet.
        let terms = try Terms([.activity: .keywords([Fixtures.boba])])
        try plan.apply(.proposalReady(SkillProposal(revision: 1, participants: [Fixtures.me, Fixtures.maya, Fixtures.jake], terms: terms)), at: Fixtures.at(minutes: 1))
        try plan.apply(.ownerAccepted(revision: 1), at: Fixtures.at(minutes: 2))
        try plan.apply(.everyoneConfirmed(revision: 1), at: Fixtures.at(minutes: 3))
        #expect(planner.suggestions(after: plan.id, in: [plan], settings: settings, cards: Fixtures.cards()).isEmpty)
    }

    @Test func swapPhotosIsHiddenWhileFlaggedOffAndOffersAnAfterPlanSwitchWhenOn() throws {
        let plan = try Fixtures.plannedDownFor()
        #expect(!planner.suggestions(after: plan.id, in: [plan], settings: settings, cards: Fixtures.cards()).contains { $0.id == .swapPhotos })

        let on = SkillSettings(flags: Fixtures.flagsWithSwapPhotos)
        let row = try #require(planner.suggestions(after: plan.id, in: [plan], settings: on, cards: Fixtures.cards()).first { $0.id == .swapPhotos })
        #expect(row.trigger == .afterPlanEnds)
        #expect(row.startsAfter == Fixtures.tonight.end)
        #expect(row.adds == SkillExposure(topics: [.photos], permissions: [.photoLibrary]))
        #expect(row.scheduled == nil)
    }

    @Test func aPlanWithNoEndCannotScheduleAnAfterPlanSkill() throws {
        let plan = try Fixtures.plannedDownFor(time: nil)
        let on = SkillSettings(flags: Fixtures.flagsWithSwapPhotos)
        #expect(!planner.suggestions(after: plan.id, in: [plan], settings: on, cards: Fixtures.cards()).contains { $0.id == .swapPhotos })
    }

    @Test func skillsTheOwnerSwitchedOffOrBlockedAreHidden() throws {
        let plan = try Fixtures.plannedDownFor()
        let off = SkillSettings(flags: .phase1_5, turnedOff: [.pickAPlace])
        #expect(planner.suggestions(after: plan.id, in: [plan], settings: off, cards: Fixtures.cards()).isEmpty)
        let never = SkillSettings(flags: .phase1_5, privacy: try PrivacySettings([.place: .never]))
        #expect(planner.suggestions(after: plan.id, in: [plan], settings: never, cards: Fixtures.cards()).isEmpty)
    }

    @Test func whatTheOwnerAllowedGrowsAlongTheChain() throws {
        let plan = try Fixtures.plannedDownFor()
        // A Pick a place link the owner said yes to: its topics and
        // permission now count as allowed for the plan.
        let first = try Self.link(after: plan, reaching: Self.agreed())
        #expect(planner.grantedExposure(for: plan, in: [plan, first]) ==
            SkillExposure(topics: [.time, .activity, .place, .location, .budget, .diet], permissions: [.locationWhenInUse]))
        let again = try #require(planner.suggestions(after: plan.id, in: [plan, first], settings: settings, cards: Fixtures.cards()).first)
        #expect(again.id == .pickAPlace)
        #expect(!again.needsConsent)
    }

    @Test func aDeclinedLinkGrantsNothing() throws {
        let plan = try Fixtures.plannedDownFor()
        let declined = try Self.link(after: plan, reaching: [.started, .consentNeeded(request: 1), .ownerPassed])
        #expect(declined.state == .ended(.declined))
        let row = try #require(planner.suggestions(after: plan.id, in: [plan, declined], settings: settings, cards: Fixtures.cards()).first)
        #expect(row.adds == SkillExposure(topics: [.location, .diet], permissions: [.locationWhenInUse]))
    }

    @Test func aLiveLinkHidesASecondOneOfTheSameSkill() throws {
        let plan = try Fixtures.plannedDownFor()
        let live = try Self.link(after: plan, reaching: [.started])
        #expect(planner.suggestions(after: plan.id, in: [plan, live], settings: settings, cards: Fixtures.cards()).isEmpty)
    }

    @Test func theRootIsFoundThroughOwnerLinksAndSurvivesACycle() throws {
        let plan = try Fixtures.plannedDownFor()
        let link = try Self.link(after: plan, reaching: Self.agreed())
        #expect(ChainPlanner.root(of: link, in: [plan, link]) == plan.id)
        #expect(ChainPlanner.root(of: link, in: [link]) == link.id)
        // Two records that name each other: stops instead of looping.
        let a = InteractionID(), b = InteractionID()
        let first = Interaction(id: a, skill: SampleSkills.pickAPlace.ref, role: .initiator, participants: [Fixtures.maya], createdAt: Fixtures.at(minutes: 0),
                                chain: ChainLink(parent: b, parentConversation: ConversationID(), consumed: [.plan], trigger: .atConfirm, optedInAt: Fixtures.at(minutes: 0)))
        let second = Interaction(id: b, skill: SampleSkills.pickAPlace.ref, role: .initiator, participants: [Fixtures.maya], createdAt: Fixtures.at(minutes: 0),
                                 chain: ChainLink(parent: a, parentConversation: ConversationID(), consumed: [.plan], trigger: .atConfirm, optedInAt: Fixtures.at(minutes: 0)))
        #expect([a, b].contains(ChainPlanner.root(of: first, in: [first, second])))
    }

    @Test func aChainGoesOnlyToThePlansAttendees() throws {
        // The Down for… asked a stranger too, who did not end up in the plan.
        var asked = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [Fixtures.maya, Fixtures.stranger, Fixtures.jake],
                                createdAt: Fixtures.at(minutes: 0))
        try asked.apply(.started, at: Fixtures.at(minutes: 1))
        let plan = try Plan(origin: asked.conversation, attendees: Attendees([Fixtures.me, Fixtures.maya, Fixtures.jake]), activity: Fixtures.boba, time: Fixtures.tonight)
        let terms = try Terms([.activity: .keywords([Fixtures.boba])])
        try asked.apply(.proposalReady(SkillProposal(revision: 1, participants: plan.attendees.peers, terms: terms, plan: plan)), at: Fixtures.at(minutes: 2))
        try asked.apply(.ownerAccepted(revision: 1), at: Fixtures.at(minutes: 3))
        try asked.apply(.everyoneConfirmed(revision: 1), at: Fixtures.at(minutes: 4))
        asked.record(.plan(plan))
        var cards = Fixtures.cards()
        cards[Fixtures.stranger] = Fixtures.card(SampleSkills.all)
        let row = try #require(planner.suggestions(after: asked.id, in: [asked], settings: settings, cards: cards).first)
        #expect(row.participants == [Fixtures.maya, Fixtures.jake])
        let start = try planner.begin(row, in: [asked], settings: settings, cards: cards, tap: OwnerTap(at: Fixtures.at(minutes: 5)),
                                      consent: row.consent(approvedAt: Fixtures.at(minutes: 5)), rules: .empty, expiresAt: Fixtures.at(minutes: 60))
        #expect(start.request.participants == [Fixtures.maya, Fixtures.jake])
        #expect(start.request.intent.audience == .picked([Fixtures.maya, Fixtures.jake]))
        #expect(start.request.intent.mode == SampleSkills.pickAPlace.defaultSendMode)
    }

    @Test func withoutAPlanThereIsNobodyToChainWith() throws {
        var slotOnly = Interaction(skill: SampleSkills.findATime.ref, role: .invitee, participants: [Fixtures.maya], createdAt: Fixtures.at(minutes: 0))
        let terms = try Terms([.time: .slots([Fixtures.tonight])])
        try slotOnly.apply(.proposalReady(SkillProposal(revision: 1, participants: [Fixtures.me, Fixtures.maya], terms: terms)), at: Fixtures.at(minutes: 1))
        try slotOnly.apply(.ownerAccepted(revision: 1), at: Fixtures.at(minutes: 2))
        try slotOnly.apply(.everyoneConfirmed(revision: 1), at: Fixtures.at(minutes: 3))
        // Find a time produced a time slot Pick a place accepts, but no plan.
        slotOnly.record(.timeSlot(Fixtures.tonight))
        #expect(planner.suggestions(after: slotOnly.id, in: [slotOnly], settings: settings, cards: Fixtures.cards()).isEmpty)
    }

    @Test func onlyTheVersionTheOwnerApprovedCountsAsGranted() throws {
        // This build's Pick a place is 1.1 and also uses people.
        let newer = try SkillDescriptor(
            ref: SkillRef(.pickAPlace, SkillVersion(1, 1)), wording: SampleSkills.pickAPlace.wording, buildingBlock: .privateAggregation,
            topicsUsed: SampleSkills.pickAPlace.topicsUsed.union([.people]), topicsRequired: [.place],
            permissions: SampleSkills.pickAPlace.permissions, accepts: [.plan, .timeSlot], produces: [.placeChoice],
            intent: SampleSkills.pickAPlace.intent
        )
        let planner = ChainPlanner(registry: try SkillRegistry([SampleSkills.downFor, newer]), me: Fixtures.me)
        let plan = try Fixtures.plannedDownFor()
        // Earlier, the owner said yes to Pick a place 1.0.
        let earlier = try Self.link(after: plan, reaching: Self.agreed())
        #expect(earlier.skill == SampleSkills.pickAPlace.ref)
        // 1.0's approval does not cover 1.1: everything 1.1 adds over Down
        // for… needs a fresh consent, people included.
        let row = try #require(planner.suggestions(after: plan.id, in: [plan, earlier], settings: settings, cards: Fixtures.cards()).first)
        #expect(row.skill.ref == newer.ref)
        #expect(row.adds == SkillExposure(topics: [.location, .diet, .people], permissions: [.locationWhenInUse]))
        #expect(planner.grantedExposure(for: plan, in: [plan, earlier]) == SampleSkills.downFor.exposure)
    }
}
