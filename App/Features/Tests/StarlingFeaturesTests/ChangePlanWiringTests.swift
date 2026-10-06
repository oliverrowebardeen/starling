import Foundation
import StarlingChaining
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
    }

    /// A leave ends only the interaction that holds the plan being left:
    /// the owner's leave chained to it, or a friend's departure grouped
    /// under it, which leaves only this phone. Change the plan can't end
    /// any other plan, even one with a suggestion open on it.
    @Test func aLeaveEndsOnlyTheInteractionHoldingThePlanBeingLeft() async throws {
        let plan = try planned()
        let other = try planned()
        var suggestion = Interaction(skill: ChangePlan.descriptor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(clock.now),
                                     chain: ChainLink(parent: other.id, parentConversation: other.planConversation, consumed: [.plan],
                                                      trigger: .whilePlanned, optedInAt: Timestamp(clock.now)))
        try suggestion.apply(.started, at: Timestamp(clock.now))
        try suggestion.apply(.proposalReady(SkillProposal(revision: 1, participants: try #require(other.plan).attendees.peers,
                                                          terms: try Terms([.activity: .keywords([try Keyword("dinner")])]))), at: Timestamp(clock.now))
        var leave = Interaction(skill: ChangePlan.descriptor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(clock.now),
                                chain: ChainLink(parent: plan.id, parentConversation: plan.planConversation, consumed: [.plan],
                                                 trigger: .whilePlanned, optedInAt: Timestamp(clock.now)))
        try leave.apply(.withdrawn, at: Timestamp(clock.now))
        let lifecycle = await coordinator([plan, other, suggestion, leave])

        await lifecycle.handle(.lifecycle(other.id, .withdrawn), from: ChangePlan.descriptor)
        #expect(lifecycle.interaction(other.id)?.state == .planned, "a suggestion is not a leave")
        await lifecycle.handle(.lifecycle(plan.id, .withdrawn), from: ChangePlan.descriptor)
        #expect(lifecycle.interaction(plan.id)?.state == .ended(.withdrawn))

        // A friend's departure grouped under the plan, which left only
        // this phone in it.
        var departure = Interaction(skill: ChangePlan.descriptor.ref, role: .invitee, participants: [maya], createdAt: Timestamp(clock.now))
        try departure.setFriendChainHint(other.planConversation)
        try departure.apply(.withdrawn, at: Timestamp(clock.now))
        let friendSide = await coordinator([other, departure])
        await friendSide.handle(.lifecycle(other.id, .withdrawn), from: ChangePlan.descriptor)
        #expect(friendSide.interaction(other.id)?.state == .ended(.withdrawn))
    }

    /// P15-E request 15: a plan is recorded only as the next revision, from
    /// any skill, so two changes can't both land on the same revision.
    @Test func aPlanRevisionOutOfTurnIsDropped() async throws {
        let plan = try planned()
        let lifecycle = await coordinator([plan])
        let current = try #require(plan.plan)
        let next = try current.updating(activity: .some(try Keyword("dinner")))
        let skipped = try next.updating(activity: .some(try Keyword("tacos")))
        await lifecycle.handle(.produced(plan.id, .plan(skipped)), from: ChangePlan.descriptor)
        await lifecycle.handle(.produced(plan.id, .plan(skipped)), from: SampleSkills.downFor)
        #expect(lifecycle.interaction(plan.id)?.plan == current)
        var stale = try #require(lifecycle.interaction(plan.id))
        stale.record(.plan(skipped))
        lifecycle.update(stale)
        #expect(lifecycle.interaction(plan.id)?.plan == current)
        var fine = try #require(lifecycle.interaction(plan.id))
        fine.record(.plan(next))
        lifecycle.update(fine)
        #expect(lifecycle.interaction(plan.id)?.plan == next)
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

/// Change the plan's words (ADR 0022, P15-E request 13): cards from the
/// owner's own nicknames, changes on the plan's timeline, and nobody named
/// when one does not go through.
@MainActor
@Suite struct ChangePlanWordsTests {
    let me = PeerID.random()
    let maya = PeerID.random()
    let jake = PeerID.random()
    let at = Timestamp(Fixtures.noon)

    var words: InteractionWords {
        let names = [maya: "Maya", jake: "Jake"]
        return InteractionWords(
            registry: try! SkillRegistry(SampleSkills.registry.descriptors + [ChangePlan.descriptor]), localPeer: me,
            formatter: ValueFormatter(timeZone: Fixtures.utc, locale: Locale(identifier: "en_US"), referenceDate: { Fixtures.noon }),
            names: { names }, now: { Fixtures.noon }
        )
    }

    func eight() throws -> TimeSlot {
        let start = Fixtures.noon.addingTimeInterval(5 * 3600 + 47 * 60) // 8 PM UTC
        return try TimeSlot(start: start, end: start.addingTimeInterval(3600))
    }

    func root() throws -> Interaction {
        var item = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya], createdAt: at)
        let plan = try Plan(origin: item.conversation, attendees: Attendees([me, maya]), activity: Keyword("boba"), time: eight())
        let proposal = SkillProposal(revision: 1, participants: [me, maya], terms: try Terms([.activity: .keywords([try Keyword("boba")])]), plan: plan)
        for event: InteractionEvent in [.started, .proposalReady(proposal), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try item.apply(event, at: at)
        }
        item.record(.plan(plan))
        return item
    }

    func suggestion(from friend: PeerID, terms: Terms, on root: Interaction) throws -> Interaction {
        var item = Interaction(skill: ChangePlan.descriptor.ref, role: .invitee, participants: [friend], createdAt: at)
        try item.setFriendChainHint(root.planConversation)
        try item.apply(.proposalReady(SkillProposal(revision: 1, participants: [me, friend], terms: terms)), at: at)
        return item
    }

    @Test func aFriendsSuggestionReadsAsWhatChanges() throws {
        let plan = try root()
        let basis = try #require(plan.plan)
        let later = try TimeSlot(start: try eight().start.addingTimeInterval(1800), end: try eight().end.addingTimeInterval(1800))
        let time = try suggestion(from: maya, terms: try Terms([.time: .slots([later])]), on: plan)
        #expect(InteractionWords.basis(of: time, among: [plan, time]) == basis)
        #expect(plain(words.suggestionCard(time, basis: basis) ?? "") == "Maya suggests 8:30 PM instead of 8 PM")
        let dinner = try suggestion(from: maya, terms: try Terms([.activity: .keywords([try Keyword("dinner")])]), on: plan)
        #expect(words.suggestionCard(dinner, basis: basis) == "Maya suggests dinner instead of boba")
        let adding = try suggestion(from: maya, terms: try Terms([.people: .peers([me, maya, jake])]), on: plan)
        #expect(words.suggestionCard(adding, basis: basis) == "Maya suggests adding Jake")
        let texts = ProposalTexts(model: nil)
        #expect(texts.text(for: dinner, words: words, basis: basis)?.headline == "Maya suggests dinner instead of boba")
    }

    @Test func aFriendBeingAddedIsAskedToJoinThePlan() throws {
        let plan = try Plan(origin: ConversationID(), attendees: Attendees([maya, jake, me]), activity: Keyword("boba"), time: eight(), revision: 1)
        var invite = Interaction(skill: ChangePlan.descriptor.ref, role: .invitee, participants: [maya], createdAt: at)
        try invite.apply(.proposalReady(SkillProposal(revision: 1, participants: plan.attendees.peers, terms: try Terms([.people: .peers(plan.attendees.peers)]), plan: plan)), at: at)
        #expect(plain(words.suggestionCard(invite, basis: nil) ?? "") == "Maya asks you to join boba with Jake, tonight at 8 PM")
    }

    @Test func homeShowsAChangeOnlyWhileItIsOpen() throws {
        let plan = try root()
        var mine = Interaction(skill: ChangePlan.descriptor.ref, role: .initiator, participants: [maya], createdAt: at,
                               chain: ChainLink(parent: plan.id, parentConversation: plan.planConversation, consumed: [.plan], trigger: .whilePlanned, optedInAt: at))
        try mine.apply(.started, at: at)
        try mine.apply(.proposalReady(SkillProposal(revision: 1, participants: [me, maya], terms: try Terms([.activity: .keywords([try Keyword("dinner")])]))), at: at)
        try mine.apply(.ownerAccepted(revision: 1), at: at)
        let waiting = HomeContent([plan, mine], words: words)
        #expect(waiting.inProgress.map(\.title) == ["Dinner instead of boba"])
        #expect(waiting.inProgress.first?.status == "Waiting for everyone to say yes")

        try mine.apply(.everyoneConfirmed(revision: 1), at: at)
        let done = HomeContent([plan, mine], words: words)
        #expect(done.comingUp.map(\.id) == [plan.id], "the change is on the plan's timeline, not a plan of its own")
        #expect(words.changeTimeline(mine, basis: plan.plan) == "Changed to dinner")
    }

    /// ADR 0022 decision 8: after a change, Add to Calendar offers the new
    /// details again.
    @Test func aChangedPlanOffersUpdateInCalendar() throws {
        var plan = try root()
        let notes = PlanNotes(file: nil)
        notes.record(.calendar, for: plan.id, revision: 0)
        #expect(!PlanDetail(root: plan, all: [plan], words: words, notes: notes).calendarIsOutdated)
        plan.record(.plan(try #require(plan.plan).updating(activity: .some(try Keyword("dinner")))))
        #expect(PlanDetail(root: plan, all: [plan], words: words, notes: notes).calendarIsOutdated)
        notes.record(.calendar, for: plan.id, revision: 1)
        #expect(!PlanDetail(root: plan, all: [plan], words: words, notes: notes).calendarIsOutdated)
    }

    @Test func theTimelineNamesNobodyWhenAChangeDoesNotGoThrough() throws {
        let plan = try root()
        var mine = Interaction(skill: ChangePlan.descriptor.ref, role: .initiator, participants: [maya], createdAt: at,
                               chain: ChainLink(parent: plan.id, parentConversation: plan.planConversation, consumed: [.plan], trigger: .whilePlanned, optedInAt: at))
        try mine.apply(.started, at: at)
        try mine.apply(.proposalReady(SkillProposal(revision: 1, participants: [me, maya], terms: try Terms([.activity: .keywords([try Keyword("dinner")])]))), at: at)
        try mine.apply(.ownerAccepted(revision: 1), at: at)
        var closed = mine
        try closed.apply(.noAgreement, at: at)
        #expect(words.changeTimeline(closed, basis: plan.plan) == "The plan stays as it was")

        var theirs = try suggestion(from: maya, terms: try Terms([.activity: .keywords([try Keyword("dinner")])]), on: plan)
        try theirs.apply(.expired, at: at)
        #expect(words.changeTimeline(theirs, basis: plan.plan) == nil)

        var left = Interaction(skill: ChangePlan.descriptor.ref, role: .invitee, participants: [maya], createdAt: at)
        try left.apply(.withdrawn, at: at)
        #expect(words.changeTimeline(left, basis: plan.plan) == "Maya left")
        var mineLeft = Interaction(skill: ChangePlan.descriptor.ref, role: .initiator, participants: [maya], createdAt: at)
        try mineLeft.apply(.withdrawn, at: at)
        #expect(words.changeTimeline(mineLeft, basis: plan.plan) == "You left this plan")
    }
}

/// "Suggest a change" and "Leave this plan" on a plan's detail (P15-E
/// request 11).
@MainActor
@Suite struct PlanChangeActionTests {
    let me = PeerID.random()
    let maya = Fixtures.peer("Maya")
    let built = AppModelTests.Built()

    func makeApp(withCard: Bool) async throws -> (AppModel, Interaction) {
        let (inbox, continuation) = AsyncStream.makeStream(of: InboxEvent.self)
        var services = AppModelTests.services(peers: InMemoryPairedPeerStore([maya]), skills: [SampleSkills.downFor, ChangePlan.descriptor],
                                              built: built, inbox: inbox, transport: RecordingTransport(localPeer: me))
        services.registry = try SkillRegistry(SampleSkills.registry.descriptors + [ChangePlan.descriptor])
        services.flags = SkillFlags(SkillFlags.phase1_5.enabled.union([.changePlan]))
        var root = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya.id], createdAt: Timestamp(Date()))
        let start = Date().addingTimeInterval(3 * 3600)
        let plan = try Plan(origin: root.conversation, attendees: Attendees([me, maya.id]), activity: Keyword("boba"), time: TimeSlot(start: start, end: start.addingTimeInterval(3600)))
        let proposal = SkillProposal(revision: 1, participants: [me, maya.id], terms: try Terms([.activity: .keywords([try Keyword("boba")])]), plan: plan)
        for event: InteractionEvent in [.started, .proposalReady(proposal), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try root.apply(event, at: Timestamp(Date()))
        }
        root.record(.plan(plan))
        services.interactions = InMemoryInteractionStore([root])
        let app = AppModel(services: services)
        await app.start()
        if withCard {
            let card = AgentCard.forBuild(skills: [SampleSkills.downFor.ref, ChangePlan.descriptor.ref], usesPSI: true, locality: .onDevice)
            continuation.yield(.message(try Envelope(conversation: ConversationID(), sender: maya.id, recipient: me, sequence: 0, sentAt: Timestamp(Date()), body: .hello(card))))
            await eventually { app.cards.card(for: maya.id) != nil }
        }
        return (app, root)
    }

    var changeService: ScriptedSkillService? { built.services.first { $0.descriptor.id == .changePlan } }

    @Test func aSuggestionStartsAndThePlanSaysWhyItCantChangeMeanwhile() async throws {
        let (app, root) = try await makeApp(withCard: true)
        #expect(app.changeUnavailableReason(for: root) == nil)
        #expect(await app.suggestChange(.change(time: nil, activity: try Keyword("dinner"), adding: nil), on: root, shown: app.changeOffer(for: root)) == nil)
        let request = try #require(await changeService?.started.first)
        #expect(request.chainedFrom == root.planConversation)
        #expect(request.participants == [maya.id])
        #expect(try PlanChange.decode(request).change == .change(time: nil, activity: try Keyword("dinner"), adding: nil))
        let link = try #require(app.lifecycle.interaction(request.interaction))
        #expect(link.chain?.parent == root.id)
        #expect(app.changeUnavailableReason(for: root) == PlanChangesInProgress.note)
        #expect(await app.suggestChange(.change(time: nil, activity: try Keyword("tacos"), adding: nil), on: root, shown: app.changeOffer(for: root)) == PlanChangesInProgress.note)
        #expect(await changeService?.started.count == 1)
    }

    /// The tap approves only what the sheet showed (ADR 0240). A row that
    /// adds more by the time of the tap is refused, and nothing starts.
    @Test func aSuggestionThatNowUsesMoreThanTheSheetShowedIsRefused() async throws {
        let (app, root) = try await makeApp(withCard: true)
        // When the sheet drew, a Find a time step on the plan had already
        // allowed people, so the row added nothing.
        var step = Interaction(skill: SampleSkills.findATime.ref, role: .initiator, participants: [maya.id], createdAt: Timestamp(Date()),
                               chain: ChainLink(parent: root.id, parentConversation: root.planConversation, consumed: [.plan],
                                                trigger: .atConfirm, optedInAt: Timestamp(Date())))
        let proposal = SkillProposal(revision: 1, participants: [me, maya.id], terms: try Terms([.activity: .keywords([try Keyword("boba")])]))
        for event: InteractionEvent in [.started, .proposalReady(proposal), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try step.apply(event, at: Timestamp(Date()))
        }
        let registry = try SkillRegistry(SampleSkills.registry.descriptors + [ChangePlan.descriptor])
        let shown = try #require(ChainPlanner(registry: registry, me: me)
            .changeOffer(for: root.id, in: [root, step], settings: app.settings.skillSettings, cards: app.cards.cards, now: Date()))
        #expect(!shown.needsConsent)
        // Now the row adds people, which the owner never saw.
        #expect(app.changeOffer(for: root)?.needsConsent == true)

        #expect(await app.suggestChange(.change(time: nil, activity: try Keyword("dinner"), adding: nil), on: root, shown: shown)
            == AppModel.changeUsesMoreNote)
        #expect(await changeService?.started.isEmpty == true)
        #expect(!app.lifecycle.interactions.contains { $0.skill.id == .changePlan })
    }

    @Test func nothingChangesWithoutEveryonesStarlingAndTheSameActivityIsNoChange() async throws {
        let (app, root) = try await makeApp(withCard: false)
        #expect(app.changeUnavailableReason(for: root) == "Not everyone's Starling can change plans yet.")
        let (withCard, plan) = try await makeApp(withCard: true)
        #expect(await withCard.suggestChange(.change(time: nil, activity: try Keyword("boba"), adding: nil), on: plan, shown: withCard.changeOffer(for: plan)) == "That's how the plan is already.")
    }

    @Test func leavingStartsWithNobodysAgreement() async throws {
        let (app, root) = try await makeApp(withCard: false)
        #expect(await app.leavePlan(root) == nil)
        let request = try #require(await changeService?.started.first)
        #expect(try PlanChange.decode(request).change == .leave)
        #expect(request.participants == [maya.id])
    }
}

/// P15-D request 15 and ADR 0233: a yes to a change of place is final, so
/// its card and detail offer no way to take it back.
@MainActor
@Suite struct PlaceYesIsFinalTests {
    let me = PeerID.random()
    let maya = PeerID.random()

    func app(planHasPlace: Bool, said: [InteractionEvent]) async throws -> (AppModel, Interaction) {
        var root = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(Date()))
        let start = Date().addingTimeInterval(3 * 3600)
        var plan = try Plan(origin: root.conversation, attendees: Attendees([me, maya]), activity: Keyword("boba"), time: TimeSlot(start: start, end: start.addingTimeInterval(3600)))
        if planHasPlace { plan = try plan.updating(place: PlaceChoice(name: PlaceName("Boba Guys"))) }
        let proposal = SkillProposal(revision: 1, participants: [me, maya], terms: try Terms([.activity: .keywords([try Keyword("boba")])]), plan: plan)
        for event: InteractionEvent in [.started, .proposalReady(proposal), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try root.apply(event, at: Timestamp(Date()))
        }
        root.record(.plan(plan))
        var change = Interaction(skill: SampleSkills.pickAPlace.ref, role: .invitee, participants: [maya], createdAt: Timestamp(Date()))
        try change.setFriendChainHint(root.planConversation)
        let place = SkillProposal(revision: 1, participants: [me, maya], terms: try Terms([.place: .places([try PlaceChoice(name: PlaceName("Tea Lab"))])]))
        try change.apply(.proposalReady(place), at: Timestamp(Date()))
        for event in said { try change.apply(event, at: Timestamp(Date())) }
        var services = AppModelTests.services(transport: RecordingTransport(localPeer: me))
        services.interactions = InMemoryInteractionStore([root, change])
        let app = AppModel(services: services)
        await app.start()
        return (app, try #require(app.lifecycle.interaction(change.id)))
    }

    @Test func aYesToAChangeOfPlaceIsFinal() async throws {
        let (app, change) = try await app(planHasPlace: true, said: [.ownerAccepted(revision: 1)])
        #expect(app.placeYesIsFinal(change))
    }

    @Test func beforeTheYesOrOnAPlansFirstPlaceItIsNot() async throws {
        let (before, card) = try await app(planHasPlace: true, said: [])
        #expect(!before.placeYesIsFinal(card))
        let (first, link) = try await app(planHasPlace: false, said: [.ownerAccepted(revision: 1)])
        #expect(!first.placeYesIsFinal(link))
    }
}
