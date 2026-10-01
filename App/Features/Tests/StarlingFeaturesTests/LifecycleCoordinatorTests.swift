import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

extension TestClock {
    var closure: @Sendable () -> Date { { [self] in now } }
}

/// A service whose start always fails.
actor FailingSkillService: SkillService {
    nonisolated let descriptor: SkillDescriptor
    nonisolated let events: AsyncStream<SkillEvent>
    init(descriptor: SkillDescriptor) {
        self.descriptor = descriptor
        events = AsyncStream { _ in }
    }
    struct Boom: Error {}
    func start(_ request: SkillRequest) async throws { throw Boom() }
    func answer(_ interaction: InteractionID, with answer: OwnerAnswer) async throws {}
    func withdraw(_ interaction: InteractionID) async {}
    func handle(_ event: InboxEvent) async {}
    func restore(_ interactions: [Interaction]) async {}
    func shutdown() async {}
}

@MainActor
@Suite struct LifecycleCoordinatorTests {
    let clock = TestClock()
    let down = ScriptedSkillService(descriptor: SampleSkills.downFor)
    let time = ScriptedSkillService(descriptor: SampleSkills.findATime)
    let maya = PeerID.random()
    let jake = PeerID.random()

    func coordinator(store: any InteractionStore = InMemoryInteractionStore()) -> LifecycleCoordinator {
        LifecycleCoordinator(registry: SampleSkills.registry, services: [down, time], store: store, now: clock.closure)
    }

    func request(_ skill: SkillDescriptor = SampleSkills.downFor, to peers: [PeerID]) -> SkillRequest {
        SkillRequest(
            interaction: InteractionID(), conversation: ConversationID(),
            intent: SkillIntent(skill: skill.ref, rules: .empty, audience: .picked(peers), mode: skill.defaultSendMode, expiresAt: Timestamp(clock.now.addingTimeInterval(3600))),
            participants: peers
        )
    }

    func proposal(_ revision: UInt32, plan: Plan? = nil) throws -> SkillProposal {
        SkillProposal(revision: revision, participants: [maya, jake], terms: try Terms([.activity: .keywords([try Keyword("boba")])]), plan: plan)
    }

    func plan(endingIn seconds: TimeInterval, origin: ConversationID) throws -> Plan {
        let start = clock.now
        return try Plan(origin: origin, attendees: Attendees([maya, jake]), activity: Keyword("boba"), time: TimeSlot(start: start, end: start.addingTimeInterval(seconds)))
    }

    static let settings = SkillSettings(flags: .phase1_5)

    // MARK: Launch

    /// Amendment 15: restore gets live interactions and those that ended in
    /// the last 24 hours, so a service can ignore a late retry.
    @Test func launchRestoresLiveAndRecentlyEndedInteractions() async throws {
        var live = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(clock.now))
        try live.apply(.started, at: Timestamp(clock.now))
        var recent = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(clock.now))
        try recent.apply(.withdrawn, at: Timestamp(clock.now.addingTimeInterval(-23 * 3600)))
        var old = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(clock.now.addingTimeInterval(-30 * 3600)))
        try old.apply(.withdrawn, at: Timestamp(clock.now.addingTimeInterval(-25 * 3600)))
        let invitee = Interaction(skill: SampleSkills.findATime.ref, role: .invitee, participants: [jake], createdAt: Timestamp(clock.now))
        let lifecycle = coordinator(store: InMemoryInteractionStore([live, recent, old, invitee]))

        await lifecycle.start()
        #expect(lifecycle.interactions.count == 4)
        #expect(Set(await down.restored.map(\.id)) == [live.id, recent.id])
        #expect(await time.restored == [invitee])
        #expect(lifecycle.isLoaded)
    }

    /// Amendment 15: a sheet does not survive the app. Requests still open
    /// at launch close with consentCancelled before restore, so the service
    /// sees the step it was in, not a suspension nobody can answer.
    @Test func sheetsLeftOpenAtLaunchAreCancelledBeforeRestore() async throws {
        var item = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(clock.now))
        try item.apply(.started, at: Timestamp(clock.now))
        try item.apply(.consentNeeded(request: 1), at: Timestamp(clock.now))
        try item.apply(.consentNeeded(request: 2), at: Timestamp(clock.now))
        let store = InMemoryInteractionStore([item])
        let lifecycle = coordinator(store: store)
        await lifecycle.start()

        let restored = try #require(await down.restored.first)
        #expect(restored.state == .negotiating)
        #expect(restored.pendingConsents.isEmpty)
        #expect(restored.consentWatermark == 2, "the closed IDs are never reused")
        #expect(lifecycle.dropped.isEmpty)
        await lifecycle.flush()
        #expect(try await store.interaction(item.id)?.state == .negotiating)
    }

    /// Amendment 15: plans end at launch, not only when the owner returns.
    @Test func plansThatEndedWhileClosedEndAtLaunch() async throws {
        var planned = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya, jake], createdAt: Timestamp(clock.now))
        for event: InteractionEvent in [.started, .proposalReady(try proposal(1)), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try planned.apply(event, at: Timestamp(clock.now))
        }
        let start = clock.now.addingTimeInterval(-3 * 3600)
        planned.record(.plan(try Plan(origin: planned.conversation, attendees: Attendees([maya, jake]), activity: Keyword("boba"), time: TimeSlot(start: start, end: start.addingTimeInterval(3600)))))
        let lifecycle = coordinator(store: InMemoryInteractionStore([planned]))
        await lifecycle.start()
        #expect(lifecycle.interaction(planned.id)?.state == .done)
    }

    /// Privacy review of PR #73: the app's journal recovery runs once the
    /// interactions are loaded and before any service is restored.
    @Test func beforeRestoreRunsBetweenLoadingAndRestoring() async throws {
        let live = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(clock.now))
        let lifecycle = coordinator(store: InMemoryInteractionStore([live]))
        var seen: (loaded: Bool, restored: Int)?
        lifecycle.beforeRestore = { [down] in
            seen = (lifecycle.interaction(live.id) != nil, await down.restored.count)
        }
        await lifecycle.start()
        #expect(seen?.loaded == true)
        #expect(seen?.restored == 0)
        #expect(await down.restored.map(\.id) == [live.id])
    }

    @Test func inboxEventsReachEveryServiceOnlyAfterRestore() async throws {
        let lifecycle = coordinator()
        await lifecycle.route(.peerAvailable(maya))
        #expect(lifecycle.isLoaded)
        #expect(await down.handled == [.peerAvailable(maya)])
        #expect(await time.handled == [.peerAvailable(maya)])
    }

    // MARK: Incoming

    @Test func anIncomingRequestBecomesANegotiatingInviteeAndNothingElse() async throws {
        let lifecycle = coordinator()
        await lifecycle.start()
        let id = InteractionID()
        let parent = ConversationID()
        await down.emit(.incoming(id, conversation: ConversationID(), from: maya, chainedFrom: parent))
        await eventually { lifecycle.interaction(id) != nil }

        let invitee = try #require(lifecycle.interaction(id))
        #expect(invitee.role == .invitee)
        #expect(invitee.state == .negotiating)
        #expect(invitee.participants == [maya])
        #expect(invitee.skill == SampleSkills.downFor.ref)
        // A peer's chainedFrom is a hint: no ChainLink, nothing started.
        #expect(invitee.chain == nil)
        #expect(await down.started.isEmpty)
    }

    /// P15-E request 4.3: a friend's chainedFrom groups their request under
    /// a plan they were in, and nothing else.
    @Test func aFriendsChainHintIsKeptOnlyForAPlanTheyWereIn() async throws {
        var plan = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(clock.now))
        for event: InteractionEvent in [.started, .proposalReady(try proposal(1)), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try plan.apply(event, at: Timestamp(clock.now))
        }
        // Lane E accepts a hint only from the plan's final attendees.
        plan.record(.plan(try self.plan(endingIn: 3600, origin: plan.conversation)))
        let lifecycle = coordinator(store: InMemoryInteractionStore([plan]))
        await lifecycle.start()

        let fromMaya = InteractionID()
        await lifecycle.handle(.incoming(fromMaya, conversation: ConversationID(), from: maya, chainedFrom: plan.conversation), from: SampleSkills.findATime)
        #expect(lifecycle.interaction(fromMaya)?.friendChainHint == plan.conversation)
        #expect(lifecycle.interaction(fromMaya)?.chain == nil)

        let stranger = PeerID.random()
        let fromStranger = InteractionID()
        await lifecycle.handle(.incoming(fromStranger, conversation: ConversationID(), from: stranger, chainedFrom: plan.conversation), from: SampleSkills.findATime)
        #expect(lifecycle.interaction(fromStranger)?.friendChainHint == nil, "not in that plan")

        let unknown = InteractionID()
        await lifecycle.handle(.incoming(unknown, conversation: ConversationID(), from: maya, chainedFrom: ConversationID()), from: SampleSkills.findATime)
        #expect(lifecycle.interaction(unknown)?.friendChainHint == nil, "no such plan")
        #expect(await time.started.isEmpty)
    }

    @Test func aRepeatedIncomingIsDropped() async throws {
        let lifecycle = coordinator()
        await lifecycle.start()
        let id = InteractionID()
        let conversation = ConversationID()
        await lifecycle.handle(.incoming(id, conversation: conversation, from: maya, chainedFrom: nil), from: SampleSkills.downFor)
        await lifecycle.handle(.incoming(id, conversation: ConversationID(), from: jake, chainedFrom: nil), from: SampleSkills.downFor)
        await lifecycle.handle(.incoming(InteractionID(), conversation: conversation, from: jake, chainedFrom: nil), from: SampleSkills.downFor)
        #expect(lifecycle.interactions.count == 1)
        #expect(lifecycle.interactions[0].participants == [maya])
        #expect(lifecycle.dropped.map(\.reason) == [.duplicateIncoming, .duplicateIncoming])
    }

    // MARK: The whole lifecycle

    @Test func aRequestGoesFromSendToPlanToDone() async throws {
        let lifecycle = coordinator()
        let sent = request(to: [maya, jake])
        let id = try await lifecycle.start(sent, settings: Self.settings)
        #expect(lifecycle.interaction(id)?.state == .negotiating)
        #expect(await down.started == [sent])

        await down.emit(.lifecycle(id, .proposalReady(try proposal(1))))
        await eventually { lifecycle.interaction(id)?.state == .proposed }
        #expect(lifecycle.interaction(id)?.proposal == (try proposal(1)))

        #expect(await lifecycle.answer(id, with: .accept(proposal: 1)))
        #expect(lifecycle.interaction(id)?.state == .confirmed)
        #expect(await down.answers.map(\.1) == [.accept(proposal: 1)])

        let plan = try plan(endingIn: 7200, origin: sent.conversation)
        await down.emit(.lifecycle(id, .everyoneConfirmed(revision: 1)))
        await down.emit(.produced(id, .plan(plan)))
        await eventually { lifecycle.interaction(id)?.plan == plan }
        #expect(lifecycle.interaction(id)?.state == .planned)

        lifecycle.tick()
        #expect(lifecycle.interaction(id)?.state == .planned)
        // Slots are whole minutes, so the end can round up by up to one.
        clock.advance(7200 + 60)
        lifecycle.tick()
        #expect(lifecycle.interaction(id)?.state == .done)
        #expect(lifecycle.interaction(id)?.history.map(\.state) == [.drafting, .negotiating, .proposed, .confirmed, .planned, .done])
        #expect(lifecycle.dropped.isEmpty)
    }

    /// ADR 0011 amendment 16: a pass hides the card and goes to the
    /// service; the record ends only when the service reports the pass.
    @Test func aPassHidesTheCardAndEndsOnlyWhenTheSkillReportsIt() async throws {
        let lifecycle = coordinator()
        var reported: [Set<InteractionID>] = []
        lifecycle.onPassedChange = { reported.append($0) }
        let id = try await lifecycle.start(request(to: [maya]), settings: Self.settings)
        await lifecycle.handle(.lifecycle(id, .proposalReady(try proposal(1))), from: SampleSkills.downFor)
        #expect(await lifecycle.answer(id, with: .pass))
        #expect(lifecycle.passed == [id])
        #expect(lifecycle.interaction(id)?.state == .proposed)
        #expect(await down.answers.map(\.1) == [.pass])

        await lifecycle.handle(.lifecycle(id, .ownerPassed), from: SampleSkills.downFor)
        #expect(lifecycle.interaction(id)?.state == .ended(.declined))
        #expect(lifecycle.passed.isEmpty)
        #expect(reported == [[id], []])
    }

    @Test func aPassOnAnEndedCardIsDroppedBeforeTheService() async throws {
        let lifecycle = coordinator()
        let id = try await lifecycle.start(request(to: [maya]), settings: Self.settings)
        await lifecycle.withdraw(id)
        #expect(await !lifecycle.answer(id, with: .pass))
        #expect(lifecycle.passed.isEmpty)
        #expect(await down.answers.isEmpty)
    }

    @Test func aPassFromAnEarlierLaunchStaysHiddenUntilItEnds() async throws {
        var open = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(clock.now))
        try open.apply(.started, at: Timestamp(clock.now))
        try open.apply(.proposalReady(try proposal(1)), at: Timestamp(clock.now))
        var ended = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya], createdAt: Timestamp(clock.now))
        try ended.apply(.withdrawn, at: Timestamp(clock.now))
        let lifecycle = coordinator(store: InMemoryInteractionStore([open, ended]))
        lifecycle.restorePassed([open.id, ended.id])
        await lifecycle.start()
        #expect(lifecycle.passed == [open.id])
    }

    @Test func withdrawingEndsTheRequestAndTellsTheService() async throws {
        let lifecycle = coordinator()
        let id = try await lifecycle.start(request(to: [maya]), settings: Self.settings)
        await lifecycle.withdraw(id)
        #expect(lifecycle.interaction(id)?.state == .ended(.withdrawn))
        #expect(await down.withdrawn == [id])
    }

    // MARK: Stale and invalid events

    /// The owner's tap on an older card never accepts newer terms, and the
    /// stale acceptance never reaches the service.
    @Test func aStaleAcceptanceIsDroppedBeforeTheService() async throws {
        let lifecycle = coordinator()
        let id = try await lifecycle.start(request(to: [maya]), settings: Self.settings)
        await lifecycle.handle(.lifecycle(id, .proposalReady(try proposal(1))), from: SampleSkills.downFor)
        await lifecycle.handle(.lifecycle(id, .proposalReady(try proposal(2))), from: SampleSkills.downFor)

        #expect(await !lifecycle.answer(id, with: .accept(proposal: 1)))
        #expect(lifecycle.interaction(id)?.state == .proposed)
        #expect(await down.answers.isEmpty)
        #expect(lifecycle.dropped.map(\.reason) == [.staleProposal(StaleProposal(current: 2, event: .ownerAccepted(revision: 1)))])
    }

    @Test func aProposalThatDoesNotMoveTheRevisionForwardIsDropped() async throws {
        let lifecycle = coordinator()
        let id = try await lifecycle.start(request(to: [maya]), settings: Self.settings)
        await lifecycle.handle(.lifecycle(id, .proposalReady(try proposal(3))), from: SampleSkills.downFor)
        await lifecycle.handle(.lifecycle(id, .proposalReady(try proposal(3))), from: SampleSkills.downFor)
        await lifecycle.handle(.lifecycle(id, .proposalReady(try proposal(2))), from: SampleSkills.downFor)
        #expect(lifecycle.interaction(id)?.proposalRevision == 3)
        #expect(lifecycle.dropped.count == 2)
        #expect(lifecycle.dropped.allSatisfy { if case .staleProposal = $0.reason { true } else { false } })
    }

    @Test func aConfirmationOfAnOlderRevisionIsDropped() async throws {
        let lifecycle = coordinator()
        let id = try await lifecycle.start(request(to: [maya]), settings: Self.settings)
        await lifecycle.handle(.lifecycle(id, .proposalReady(try proposal(1))), from: SampleSkills.downFor)
        await lifecycle.answer(id, with: .accept(proposal: 1))
        await lifecycle.handle(.lifecycle(id, .everyoneConfirmed(revision: 0)), from: SampleSkills.downFor)
        #expect(lifecycle.interaction(id)?.state == .confirmed)
        #expect(lifecycle.dropped.map(\.reason) == [.staleProposal(StaleProposal(current: 1, event: .everyoneConfirmed(revision: 0)))])
    }

    @Test func questionsBindToTheirRevision() async throws {
        let lifecycle = coordinator()
        let id = InteractionID()
        await lifecycle.start()
        await lifecycle.handle(.incoming(id, conversation: ConversationID(), from: maya, chainedFrom: nil), from: SampleSkills.findATime)
        let slot = try TimeSlot(start: clock.now, end: clock.now.addingTimeInterval(3600))
        let question = SkillQuestion(revision: 1, issue: .time, candidates: .slots([slot]), asker: maya)
        await lifecycle.handle(.lifecycle(id, .ownerNeeded(question)), from: SampleSkills.findATime)
        #expect(lifecycle.interaction(id)?.state == .awaitingOwner)
        #expect(lifecycle.interaction(id)?.pendingQuestion == question)

        #expect(await !lifecycle.answer(id, with: .reply(question: 2, .slots([slot]))))
        #expect(await time.answers.isEmpty)
        #expect(await lifecycle.answer(id, with: .reply(question: 1, .slots([slot]))))
        #expect(lifecycle.interaction(id)?.state == .negotiating)
        #expect(await time.answers.map(\.1) == [.reply(question: 1, .slots([slot]))])

        // A replay of the answered question cannot reopen it.
        await lifecycle.handle(.lifecycle(id, .ownerNeeded(question)), from: SampleSkills.findATime)
        #expect(lifecycle.interaction(id)?.state == .negotiating)
        #expect(lifecycle.dropped.count == 2)
        #expect(lifecycle.dropped.allSatisfy { if case .staleQuestion = $0.reason { true } else { false } })
    }

    @Test func eventsAfterAFinalStateAreDropped() async throws {
        let lifecycle = coordinator()
        let id = try await lifecycle.start(request(to: [maya]), settings: Self.settings)
        await lifecycle.handle(.lifecycle(id, .noAgreement), from: SampleSkills.downFor)
        #expect(lifecycle.interaction(id)?.state == .ended(.nobodyUp))
        await lifecycle.handle(.lifecycle(id, .proposalReady(try proposal(1))), from: SampleSkills.downFor)
        await lifecycle.handle(.lifecycle(id, .started), from: SampleSkills.downFor)
        #expect(lifecycle.interaction(id)?.state == .ended(.nobodyUp))
        #expect(lifecycle.interaction(id)?.proposal == nil)
        #expect(lifecycle.dropped.count == 2)
        #expect(lifecycle.dropped.allSatisfy { if case .invalidTransition = $0.reason { true } else { false } })
    }

    @Test func anInvalidTransitionLeavesTheRecordUnchanged() async throws {
        let lifecycle = coordinator()
        let id = try await lifecycle.start(request(to: [maya]), settings: Self.settings)
        let before = try #require(lifecycle.interaction(id))
        await lifecycle.handle(.lifecycle(id, .everyoneConfirmed(revision: 0)), from: SampleSkills.downFor)
        await lifecycle.handle(.lifecycle(id, .planEnded), from: SampleSkills.downFor)
        #expect(lifecycle.interaction(id) == before)
        #expect(lifecycle.dropped.count == 2)
    }

    @Test func eventsForUnknownOrForeignInteractionsAreDropped() async throws {
        let lifecycle = coordinator()
        let id = try await lifecycle.start(request(to: [maya]), settings: Self.settings)
        await lifecycle.handle(.lifecycle(InteractionID(), .noAgreement), from: SampleSkills.downFor)
        await lifecycle.handle(.produced(InteractionID(), .timeSlot(try TimeSlot(start: clock.now, end: clock.now.addingTimeInterval(60)))), from: SampleSkills.downFor)
        // Find a time's service cannot move Down for…'s interaction.
        await lifecycle.handle(.lifecycle(id, .noAgreement), from: SampleSkills.findATime)
        #expect(lifecycle.interaction(id)?.state == .negotiating)
        #expect(lifecycle.dropped.map(\.reason) == [.unknownInteraction, .unknownInteraction, .wrongSkill])
    }

    @Test func anArtifactAfterTheEndIsDropped() async throws {
        let lifecycle = coordinator()
        let sent = request(to: [maya, jake])
        let id = try await lifecycle.start(sent, settings: Self.settings)
        await lifecycle.handle(.lifecycle(id, .expired), from: SampleSkills.downFor)
        await lifecycle.handle(.produced(id, .plan(try plan(endingIn: 60, origin: sent.conversation))), from: SampleSkills.downFor)
        #expect(lifecycle.interaction(id)?.artifacts.isEmpty == true)
        #expect(lifecycle.dropped.map(\.reason) == [.afterEnd])
    }

    /// ADR 0011 amendment 14: a denied send ends any live step, such as an
    /// invitee's acceptance, but never calls off an agreed plan.
    @Test func aPolicyDenialEndsALiveStepButNotAPlan() async throws {
        let lifecycle = coordinator()
        await lifecycle.start()
        let id = InteractionID()
        await lifecycle.handle(.incoming(id, conversation: ConversationID(), from: maya, chainedFrom: nil), from: SampleSkills.downFor)
        await lifecycle.handle(.lifecycle(id, .proposalReady(try proposal(1))), from: SampleSkills.downFor)
        await lifecycle.answer(id, with: .accept(proposal: 1))
        await lifecycle.handle(.lifecycle(id, .blockedByPrivacy), from: SampleSkills.downFor)
        #expect(lifecycle.interaction(id)?.state == .ended(.blockedByPrivacy))

        let sent = request(to: [maya])
        let planned = try await lifecycle.start(sent, settings: Self.settings)
        await lifecycle.handle(.lifecycle(planned, .proposalReady(try proposal(1))), from: SampleSkills.downFor)
        await lifecycle.answer(planned, with: .accept(proposal: 1))
        await lifecycle.handle(.lifecycle(planned, .everyoneConfirmed(revision: 1)), from: SampleSkills.downFor)
        await lifecycle.handle(.lifecycle(planned, .blockedByPrivacy), from: SampleSkills.downFor)
        #expect(lifecycle.interaction(planned)?.state == .planned)
        #expect(lifecycle.dropped.count == 1)
    }

    @Test func theDropLogIsBounded() async throws {
        let lifecycle = coordinator()
        await lifecycle.start()
        for _ in 0..<(LifecycleCoordinator.maxDropped + 5) {
            await lifecycle.handle(.lifecycle(InteractionID(), .noAgreement), from: SampleSkills.downFor)
        }
        #expect(lifecycle.dropped.count == LifecycleCoordinator.maxDropped)
    }

    // MARK: Consent

    @Test func consentSuspendsAndResumesTheInterruptedStep() async throws {
        let lifecycle = coordinator()
        let sent = request(to: [maya])
        let id = try await lifecycle.start(sent, settings: Self.settings)
        let first = try #require(lifecycle.consentRequested(conversation: sent.conversation))
        let second = try #require(lifecycle.consentRequested(conversation: sent.conversation))
        #expect((first, second) == (1, 2))
        #expect(lifecycle.interaction(id)?.state == .awaitingConsent(resume: .negotiating))
        #expect(lifecycle.interaction(id)?.state.homeSection == .needsYou)

        lifecycle.consentAnswered(conversation: sent.conversation, request: first, approved: true)
        #expect(lifecycle.interaction(id)?.state == .awaitingConsent(resume: .negotiating))
        lifecycle.consentAnswered(conversation: sent.conversation, request: second, approved: true)
        #expect(lifecycle.interaction(id)?.state == .negotiating)

        // A late or replayed completion never resumes a later suspension.
        let third = try #require(lifecycle.consentRequested(conversation: sent.conversation))
        lifecycle.consentAnswered(conversation: sent.conversation, request: first, approved: true)
        #expect(lifecycle.interaction(id)?.state == .awaitingConsent(resume: .negotiating))
        #expect(lifecycle.dropped.map(\.reason) == [.unknownConsentRequest(UnknownConsentRequest(request: first))])
        lifecycle.consentAnswered(conversation: sent.conversation, request: third, approved: false)
        #expect(lifecycle.interaction(id)?.state == .ended(.declined))
    }

    /// Amendment 15: a proposal or question reported while a sheet is up
    /// is kept and applied, in order, once the step resumes.
    @Test func progressDuringASuspensionAppliesAfterItResumes() async throws {
        let lifecycle = coordinator()
        let sent = request(to: [maya])
        let id = try await lifecycle.start(sent, settings: Self.settings)
        let first = try #require(lifecycle.consentRequested(conversation: sent.conversation))
        let second = try #require(lifecycle.consentRequested(conversation: sent.conversation))
        await lifecycle.handle(.lifecycle(id, .proposalReady(try proposal(1))), from: SampleSkills.downFor)
        await lifecycle.handle(.lifecycle(id, .proposalReady(try proposal(2))), from: SampleSkills.downFor)
        #expect(lifecycle.interaction(id)?.state == .awaitingConsent(resume: .negotiating))
        #expect(lifecycle.dropped.isEmpty)

        lifecycle.consentAnswered(conversation: sent.conversation, request: first, approved: true)
        #expect(lifecycle.interaction(id)?.proposal == nil, "still suspended on the second sheet")
        lifecycle.consentAnswered(conversation: sent.conversation, request: second, approved: true)
        #expect(lifecycle.interaction(id)?.state == .proposed)
        #expect(lifecycle.interaction(id)?.proposalRevision == 2)
        #expect(lifecycle.dropped.isEmpty)
    }

    /// A final event during a suspension applies at once and ends the
    /// pending sheets with it; held progress is discarded.
    @Test func anEndDuringASuspensionAppliesAtOnce() async throws {
        let lifecycle = coordinator()
        var finished: [ConversationID] = []
        lifecycle.onFinished = { _, conversation in finished.append(conversation) }
        let sent = request(to: [maya])
        let id = try await lifecycle.start(sent, settings: Self.settings)
        let request = try #require(lifecycle.consentRequested(conversation: sent.conversation))
        await lifecycle.handle(.lifecycle(id, .proposalReady(try proposal(1))), from: SampleSkills.downFor)
        await lifecycle.handle(.lifecycle(id, .noAgreement), from: SampleSkills.downFor)
        #expect(lifecycle.interaction(id)?.state == .ended(.nobodyUp))
        #expect(lifecycle.interaction(id)?.pendingConsents.isEmpty == true)
        #expect(finished == [sent.conversation])
        #expect(!lifecycle.consentAnswered(conversation: sent.conversation, request: request, approved: true))
        #expect(lifecycle.interaction(id)?.proposal == nil)
        #expect(lifecycle.isFinished(conversation: sent.conversation))
    }

    @Test func consentOutsideAnyInteractionIsNotTracked() async throws {
        let lifecycle = coordinator()
        await lifecycle.start()
        #expect(lifecycle.consentRequested(conversation: ConversationID()) == nil)
        #expect(lifecycle.dropped.isEmpty)
    }

    /// The coordinator is lane E's EgressSink: a record lands on the
    /// conversation's interaction once, is saved before it returns, and a
    /// conversation nobody owns reports false.
    @Test func egressIsRecordedOnTheInteractionThatSentIt() async throws {
        let store = InMemoryInteractionStore()
        let lifecycle = coordinator(store: store)
        let sent = request(to: [maya])
        let id = try await lifecycle.start(sent, settings: Self.settings)
        let record = EgressRecord(at: Timestamp(clock.now), recipient: maya, items: [DisclosedItem(category: .terms, issue: .activity, value: .keywords([try Keyword("boba")]))],
                                  message: MessageID())
        #expect(try await lifecycle.appendEgress(record, conversation: sent.conversation))
        #expect(try await lifecycle.appendEgress(record, conversation: sent.conversation), "a repeat is ignored")
        #expect(try await !lifecycle.appendEgress(record, conversation: ConversationID()))
        #expect(lifecycle.interaction(id)?.egress == [record])
        #expect(try await store.interaction(id)?.egress == [record], "saved before it returned")
    }

    @Test func anEgressRecordThatCannotBeSavedThrowsSoTheRecorderRetries() async throws {
        let store = BlockingStore()
        let lifecycle = coordinator(store: store)
        let sent = request(to: [maya])
        _ = try await lifecycle.start(sent, settings: Self.settings)
        await store.failSaves()
        let record = EgressRecord(at: Timestamp(clock.now), recipient: maya, items: [], message: MessageID())
        await #expect(throws: EgressNotSaved.self) { try await lifecycle.appendEgress(record, conversation: sent.conversation) }
    }

    // MARK: Starting

    @Test func aRequestNobodyCanRunIsRecordedAsUnsupported() async throws {
        let lifecycle = coordinator()
        let sent = request(to: [])
        await #expect(throws: StartRefusal.unsupported) { try await lifecycle.start(sent, settings: Self.settings) }
        #expect(lifecycle.interaction(sent.interaction)?.state == .ended(.unsupported))
        #expect(await down.started.isEmpty)
    }

    @Test func aSkillBlockedByPrivacyExplainsInsteadOfSending() async throws {
        let lifecycle = coordinator()
        let sent = request(SampleSkills.findATime, to: [maya])
        var privacy = PrivacySettings.defaults
        try privacy.set(.share, for: .time)
        let settings = SkillSettings(flags: .phase1_5, privacy: privacy)
        _ = try await lifecycle.start(sent, settings: settings)

        let pickAPlace = ScriptedSkillService(descriptor: SampleSkills.pickAPlace)
        let withPlace = LifecycleCoordinator(registry: SampleSkills.registry, services: [pickAPlace], store: InMemoryInteractionStore(), now: clock.closure)
        try privacy.set(.never, for: .place)
        let blocked = request(SampleSkills.pickAPlace, to: [maya])
        await #expect(throws: StartRefusal.blockedByPrivacy([.place])) {
            try await withPlace.start(blocked, settings: SkillSettings(flags: .phase1_5, privacy: privacy))
        }
        #expect(withPlace.interaction(blocked.interaction)?.state == .ended(.blockedByPrivacy))
        #expect(await pickAPlace.started.isEmpty)
    }

    @Test func aSkillNotInTheBuildIsRefused() async throws {
        let lifecycle = coordinator()
        await #expect(throws: StartRefusal.notInThisBuild) {
            try await lifecycle.start(request(SampleSkills.pickAPlace, to: [maya]), settings: Self.settings)
        }
        #expect(lifecycle.interactions.isEmpty)
    }

    @Test func aServiceThatCannotStartEndsTheInteractionFailed() async throws {
        let failing = FailingSkillService(descriptor: SampleSkills.downFor)
        let lifecycle = LifecycleCoordinator(registry: SampleSkills.registry, services: [failing], store: InMemoryInteractionStore(), now: clock.closure)
        let sent = request(to: [maya])
        await #expect(throws: StartRefusal.self) { try await lifecycle.start(sent, settings: Self.settings) }
        #expect(lifecycle.interaction(sent.interaction)?.state == .ended(.failed))
    }

    // MARK: Saving before sending (re-review of PR #54, finding 3)

    /// The service starts only once the started interaction is on disk.
    @Test func theServiceStartsOnlyAfterTheRecordIsSaved() async throws {
        let store = BlockingStore()
        let lifecycle = coordinator(store: store)
        await lifecycle.start()
        let sent = request(to: [maya])
        await store.block()
        let starting = Task { try await lifecycle.start(sent, settings: Self.settings) }
        for _ in 0..<2000 where await store.waiting == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await store.waiting == 1)
        #expect(await down.started.isEmpty, "nothing is sent while the save is pending")
        #expect(lifecycle.interaction(sent.interaction) == nil)

        await store.release()
        _ = try await starting.value
        #expect(await down.started.map(\.interaction) == [sent.interaction])
        #expect(try await store.interaction(sent.interaction)?.state == .negotiating)
    }

    @Test func aSaveThatFailsRefusesTheStart() async throws {
        let store = BlockingStore()
        let lifecycle = coordinator(store: store)
        await lifecycle.start()
        await store.failSaves()
        let sent = request(to: [maya])
        await #expect(throws: StartRefusal.notSaved) { try await lifecycle.start(sent, settings: Self.settings) }
        #expect(await down.started.isEmpty)
        #expect(lifecycle.interaction(sent.interaction) == nil)
    }

    // MARK: Persistence

    @Test func everyChangeIsSavedAndSurvivesARestart() async throws {
        let store = InMemoryInteractionStore()
        let lifecycle = coordinator(store: store)
        let id = try await lifecycle.start(request(to: [maya]), settings: Self.settings)
        await lifecycle.handle(.lifecycle(id, .proposalReady(try proposal(4))), from: SampleSkills.downFor)
        await lifecycle.flush()
        let saved = try #require(try await store.interaction(id))
        #expect(saved == lifecycle.interaction(id))

        let down2 = ScriptedSkillService(descriptor: SampleSkills.downFor)
        let restarted = LifecycleCoordinator(registry: SampleSkills.registry, services: [down2], store: store, now: clock.closure)
        await restarted.start()
        #expect(await down2.restored.map(\.proposal) == [try proposal(4)])
        // The card is rebuilt from the store, and a stale tap still fails.
        #expect(await !restarted.answer(id, with: .accept(proposal: 3)))
        #expect(await restarted.answer(id, with: .accept(proposal: 4)))
    }

    @Test func changesAreReportedForNotifications() async throws {
        let lifecycle = coordinator()
        var seen: [(InteractionState?, InteractionState)] = []
        lifecycle.onChange = { before, after in seen.append((before?.state, after.state)) }
        let id = try await lifecycle.start(request(to: [maya]), settings: Self.settings)
        await lifecycle.handle(.lifecycle(id, .proposalReady(try proposal(1))), from: SampleSkills.downFor)
        await lifecycle.handle(.lifecycle(id, .proposalReady(try proposal(1))), from: SampleSkills.downFor)
        // A request appears once it is saved as started; its history still
        // begins with drafting.
        #expect(seen.map(\.1) == [.negotiating, .proposed])
        #expect(seen.map(\.0) == [nil, .negotiating])
        #expect(lifecycle.interaction(id)?.history.first?.state == .drafting)
    }
}

/// An interaction store whose saves can be held or made to fail.
actor BlockingStore: InteractionStore {
    struct Failure: Error {}
    private let base = InMemoryInteractionStore()
    private var blocked = false
    private var failing = false
    private var held: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { held.count }

    func block() { blocked = true }
    func release() {
        blocked = false
        held.forEach { $0.resume() }
        held = []
    }
    func failSaves() { failing = true }

    func all() async throws -> [Interaction] { try await base.all() }
    func interaction(_ id: InteractionID) async throws -> Interaction? { try await base.interaction(id) }
    func interaction(conversation: ConversationID) async throws -> Interaction? { try await base.interaction(conversation: conversation) }
    func save(_ interaction: Interaction) async throws {
        if failing { throw Failure() }
        if blocked { await withCheckedContinuation { held.append($0) } }
        try await base.save(interaction)
    }
    func remove(_ id: InteractionID) async throws { try await base.remove(id) }
}
