import Foundation
import PickAPlace
import StarlingChangePlan
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

/// ADR 0023: a phone takes part in one change per plan at a time. The app
/// says "Another change to this plan is in progress" where a second change
/// would start or get a yes.
@MainActor
@Suite struct ChangeInProgressTests {
    let me = PeerID.random()
    let maya = PeerID.random()
    let holds = PlanChangeHolds()

    func planned() throws -> Interaction {
        var root = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(Date()))
        let start = Date().addingTimeInterval(3 * 3600)
        let plan = try Plan(origin: root.conversation, attendees: Attendees([me, maya]), activity: Keyword("boba"), time: TimeSlot(start: start, end: start.addingTimeInterval(3600)))
        let proposal = SkillProposal(revision: 1, participants: [me, maya], terms: try Terms([.activity: .keywords([try Keyword("boba")])]), plan: plan)
        for event: InteractionEvent in [.started, .proposalReady(proposal), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try root.apply(event, at: Timestamp(Date()))
        }
        root.record(.plan(plan))
        return root
    }

    /// Maya's change of place, waiting for this owner's answer.
    func placeCard(on root: Interaction) throws -> Interaction {
        var card = Interaction(skill: SampleSkills.pickAPlace.ref, role: .invitee, participants: [maya], createdAt: Timestamp(Date()))
        try card.setFriendChainHint(root.planConversation)
        let place = SkillProposal(revision: 1, participants: [me, maya], terms: try Terms([.place: .places([try PlaceChoice(name: PlaceName("Tea Lab"))])]))
        try card.apply(.proposalReady(place), at: Timestamp(Date()))
        return card
    }

    func app(_ items: [Interaction]) async -> AppModel {
        var services = AppModelTests.services(skills: [SampleSkills.downFor, SampleSkills.pickAPlace], transport: RecordingTransport(localPeer: me))
        services.interactions = InMemoryInteractionStore(items)
        services.changesInProgress = PlanChangesInProgress(holds)
        let app = AppModel(services: services)
        await app.start()
        return app
    }

    @Test func aFriendsCardForASecondChangeOffersNoYes() async throws {
        let root = try planned()
        let card = try placeCard(on: root)
        let origin = try #require(root.plan?.origin)
        let other = ConversationID()
        // Held before launch, as a skill holds a change it restores.
        #expect(await holds.hold(origin, for: other))
        let app = await app([root, card])
        await eventually { app.answerLimit(card) != nil }
        #expect(app.answerLimit(card) == .anotherChangeInProgress)
        #expect(AnswerLimit.anotherChangeInProgress.offersNo)
        #expect(AnswerLimit.anotherChangeInProgress.note == "Another change to this plan is in progress.")

        // The first change ends: the yes is back, with nothing else on the
        // phone changing (P15-A request 8).
        await holds.release(origin, for: other)
        await eventually { app.answerLimit(card) == nil }
        #expect(app.answerLimit(card) == nil)
    }

    /// The card's own change holding the plan is no reason to hide its yes;
    /// another change taking the plan hides it at once.
    @Test func onlyAnotherChangesHoldHidesTheYes() async throws {
        let root = try planned()
        let first = try placeCard(on: root)
        let second = try placeCard(on: root)
        let app = await app([root, first, second])
        let origin = try #require(root.plan?.origin)
        // The skill holds the plan before it sends the yes to the first.
        #expect(await holds.hold(origin, for: first.conversation))
        await eventually { app.answerLimit(second) != nil }
        #expect(app.answerLimit(second) == .anotherChangeInProgress)
        #expect(app.answerLimit(first) == nil)
    }

    @Test func noChangeStartsWhileAnotherHoldsThePlan() async throws {
        let root = try planned()
        let app = await app([root])
        let origin = try #require(root.plan?.origin)
        #expect(await holds.hold(origin, for: ConversationID()))
        await eventually { app.services.changesInProgress?.isHeld(origin) == true }
        #expect(app.changeUnavailableReason(for: root) == PlanChangesInProgress.note)
        #expect(await app.suggestChange(.change(time: nil, activity: try Keyword("dinner"), adding: nil), on: root, shown: app.changeOffer(for: root)) == PlanChangesInProgress.note)
        // Keep it going's Pick a place says the same before the tap.
        #expect(app.composer.planIsChanging(root.id))
        // Leaving needs no hold (ADR 0023 decision 4).
        #expect(await app.leavePlan(root) != PlanChangesInProgress.note)
    }

    /// The skill would turn a yes away while another change holds the
    /// plan, after the card had moved on; the app asks the holds first.
    @Test func aYesWaitsWhileAnotherChangeHoldsThePlan() async throws {
        let root = try planned()
        let card = try placeCard(on: root)
        let app = await app([root, card])
        let origin = try #require(root.plan?.origin)
        let other = ConversationID()
        #expect(await holds.hold(origin, for: other))
        #expect(await !app.answer(card.id, with: .accept(proposal: 1)))
        #expect(app.lifecycle.interaction(card.id)?.state == .proposed)

        await holds.release(origin, for: other)
        #expect(await app.answer(card.id, with: .accept(proposal: 1)))
        #expect(app.lifecycle.interaction(card.id)?.state != .proposed)
    }

    /// Change the plan that refuses as lane E's does when the plan is held.
    actor BusyChangePlan: SkillService {
        nonisolated let descriptor = ChangePlan.descriptor
        nonisolated let events = AsyncStream<SkillEvent> { _ in }
        func start(_ request: SkillRequest) async throws { throw ChangePlanError.planBusy }
        func answer(_ interaction: InteractionID, with answer: OwnerAnswer) async throws {}
        func withdraw(_ interaction: InteractionID) async {}
        func handle(_ event: InboxEvent) async {}
        func restore(_ interactions: [Interaction]) async {}
        func shutdown() async {}
    }

    @Test func aStartTheSkillRefusesForAHeldPlanSaysSo() async throws {
        let registry = try SkillRegistry(SampleSkills.registry.descriptors + [ChangePlan.descriptor])
        let lifecycle = LifecycleCoordinator(registry: registry, services: [BusyChangePlan()], store: InMemoryInteractionStore())
        await lifecycle.start()
        let request = SkillRequest(
            interaction: InteractionID(), conversation: ConversationID(),
            intent: SkillIntent(skill: ChangePlan.descriptor.ref, rules: .empty, audience: .picked([maya]), mode: .invite,
                                expiresAt: Timestamp(Date().addingTimeInterval(3600))),
            participants: [maya]
        )
        do {
            _ = try await lifecycle.start(request, settings: SkillSettings(flags: .phase1_5))
            Issue.record("a busy plan started")
        } catch {
            #expect(error == .planChangeInProgress)
            #expect(ComposerModel.refusalNote(error, ChangePlan.descriptor) == PlanChangesInProgress.note)
        }
        #expect(PlanChangesInProgress.isRefusal(PickAPlaceError.planChangeInProgress))
        #expect(!PlanChangesInProgress.isRefusal(PickAPlaceError.alreadyStarted))
    }
}
