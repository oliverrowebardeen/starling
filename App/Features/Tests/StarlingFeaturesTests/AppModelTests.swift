import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

@MainActor
@Suite struct AppModelTests {
    final class Built: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (outbox: Outbox, services: [ScriptedSkillService])?
        func set(_ outbox: Outbox, _ services: [ScriptedSkillService]) { lock.withLock { value = (outbox, services) } }
        var outbox: Outbox? { lock.withLock { value?.outbox } }
        var services: [ScriptedSkillService] { lock.withLock { value?.services ?? [] } }
    }

    static func services(
        peers: InMemoryPairedPeerStore? = InMemoryPairedPeerStore(),
        skills: [SkillDescriptor] = [SampleSkills.downFor, SampleSkills.findATime],
        built: Built? = nil,
        inbox: AsyncStream<InboxEvent>? = nil,
        transport: RecordingTransport = RecordingTransport(),
        locality: ModelLocality? = .onDevice,
        prompter: CountingPrompter = CountingPrompter(),
        notifier: RecordingNotifier = RecordingNotifier(),
        settings: any OwnerSettingsStore = InMemoryOwnerSettingsStore()
    ) -> AppServices {
        AppServices(
            registry: SampleSkills.registry,
            makeSkills: { outbox in
                let services = skills.map(ScriptedSkillService.init(descriptor:))
                built?.set(outbox, services)
                return services
            },
            interactions: InMemoryInteractionStore(),
            settings: settings,
            rules: InMemoryRulesStore(),
            peers: peers,
            pairing: PairingModelTests.scripted().directory,
            unpair: { peer in try await peers?.remove(peer) },
            inboxEvents: inbox,
            makePolicy: { _, _ in FixedPolicyEngine(.allow) },
            transport: transport,
            agentLocality: locality,
            notifier: notifier,
            localNetwork: prompter
        )
    }

    @Test func buildsEverySkillOnTheAppsOutbox() async {
        let built = Built()
        let app = AppModel(services: Self.services(built: built))
        #expect(built.outbox === app.outbox)
        #expect(app.lifecycle.skillsInBuild == [.downFor, .findATime])
    }

    @Test func noSkillsWithoutAnOutbox() {
        var services = Self.services()
        services.transport = nil
        let app = AppModel(services: services)
        #expect(app.outbox == nil)
        #expect(app.lifecycle.skillsInBuild.isEmpty)
    }

    /// ADR 0013: nothing is asked at launch. The radios, and with them the
    /// Local Network alert, wait for the first Pair or request.
    @Test func launchAsksForNothingAndTheFirstRequestAsksForLocalNetworkOnce() async {
        let transport = RecordingTransport()
        let prompter = CountingPrompter()
        let notifier = RecordingNotifier()
        let app = AppModel(services: Self.services(transport: transport, prompter: prompter, notifier: notifier))
        await app.start()
        #expect(await transport.isStarted == false)
        #expect(await prompter.prompts == 0)
        #expect(await notifier.authorizationRequests == 0)

        await app.ensureLocalNetwork()
        await app.ensureLocalNetwork()
        #expect(await prompter.prompts == 1)
        #expect(await transport.isStarted)
        #expect(app.settings.settings.localNetworkAsked)
    }

    @Test func onceAskedTheRadiosStartAtLaunch() async {
        var settings = OwnerSettings()
        settings.localNetworkAsked = true
        let transport = RecordingTransport()
        let prompter = CountingPrompter()
        let app = AppModel(services: Self.services(transport: transport, prompter: prompter, settings: InMemoryOwnerSettingsStore(settings)))
        await app.start()
        #expect(await transport.isStarted)
        #expect(await prompter.prompts == 0)
    }

    @Test func notificationsAreAskedOnlyWhenTheOwnerSaysYes() async {
        let notifier = RecordingNotifier()
        let app = AppModel(services: Self.services(notifier: notifier))
        await app.start()
        await app.answerNotifications(false)
        #expect(await notifier.authorizationRequests == 0)
        #expect(app.settings.settings.notificationsOffered)
        await app.answerNotifications(true)
        #expect(await notifier.authorizationRequests == 1)
        #expect(app.notificationsAllowed == true)
    }

    @Test func shutdownStopsTheSkillsAndTheTransport() async {
        let transport = RecordingTransport()
        let app = AppModel(services: Self.services(transport: transport))
        await app.start()
        await app.ensureLocalNetwork()
        await app.shutdown()
        #expect(await transport.isStarted == false)
    }

    /// The link layer greets each friend with this agent's card, which lists
    /// the skills in the build and switched on (ADR 0010).
    @Test func greetsEachPeerWithACardListingItsSkills() async throws {
        let transport = RecordingTransport()
        let (inbox, continuation) = AsyncStream.makeStream(of: InboxEvent.self)
        let app = AppModel(services: Self.services(inbox: inbox, transport: transport))
        await app.start()
        let card = try #require(app.agentCard)
        #expect(card.skills == [SampleSkills.downFor.ref, SampleSkills.findATime.ref])
        #expect(card.capabilities == [.psi])

        let friend = PeerID.random()
        continuation.yield(.peerAvailable(friend))
        for _ in 0..<2000 where await transport.sent.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        let sent = try #require(await transport.sent.first)
        #expect(try EnvelopeCodec().decode(sent.frame.bytes).body == .hello(card))
    }

    /// A skill the owner switches off leaves the card; one blocked only by a
    /// Never topic stays, so the card never reveals privacy choices.
    @Test func theCardFollowsSkillSwitchesButNotPrivacy() async throws {
        let app = AppModel(services: Self.services())
        await app.start()
        await app.settings.setSkill(.findATime, on: false)
        #expect(app.agentCard?.skills == [SampleSkills.downFor.ref])
        #expect(app.link?.card == app.agentCard)
        await app.settings.setSkill(.findATime, on: true)
        await app.settings.set(.never, for: .budget)
        #expect(app.agentCard?.skills == [SampleSkills.downFor.ref, SampleSkills.findATime.ref])
    }

    @Test func routesEveryInboxEventToEverySkillInOrder() async throws {
        let built = Built()
        let (inbox, continuation) = AsyncStream.makeStream(of: InboxEvent.self)
        let app = AppModel(services: Self.services(built: built, inbox: inbox))
        await app.start()
        let friend = PeerID.random()
        let envelope = try Envelope(
            conversation: ConversationID(), sender: friend, recipient: .random(), sequence: 0,
            sentAt: Timestamp(Fixtures.noon), body: .propose(try Proposal(round: 0, terms: .empty))
        )
        let events: [InboxEvent] = [.peerAvailable(friend), .message(envelope), .dropped(from: friend, reason: .replay), .peerUnavailable(friend)]
        events.forEach { continuation.yield($0) }
        for service in built.services {
            for _ in 0..<2000 where await service.handled.count < events.count { try await Task.sleep(for: .milliseconds(1)) }
            #expect(await service.handled == events)
        }
    }

    @Test func friendsSeeReachabilityAndCards() async throws {
        let maya = Fixtures.peer("Maya")
        let (inbox, continuation) = AsyncStream.makeStream(of: InboxEvent.self)
        let app = AppModel(services: Self.services(peers: InMemoryPairedPeerStore([maya]), inbox: inbox))
        await app.start()
        continuation.yield(.peerAvailable(maya.id))
        let card = AgentCard.forBuild(skills: [SampleSkills.downFor.ref], usesPSI: true, locality: .onDevice)
        continuation.yield(.message(try Envelope(conversation: ConversationID(), sender: maya.id, recipient: .random(), sequence: 0, sentAt: Timestamp(Date()), body: .hello(card))))
        await eventually { app.friends?.isReachable(maya.id) == true && app.cards.card(for: maya.id) != nil }
        #expect(app.cards.card(for: maya.id) == card)
    }

    /// Lane E1: each PairingService starts after its transport.
    @Test func afterStartRunsOnceTheTransportHasStarted() async {
        let transport = RecordingTransport()
        let sawStarted = Recorder<Bool>()
        var services = Self.services(transport: transport)
        services.afterStart = { await sawStarted.record(await transport.isStarted) }
        let app = AppModel(services: services)
        await app.start()
        #expect(await sawStarted.values.isEmpty)
        await app.startLinks()
        await app.startLinks()
        #expect(await sawStarted.values == [true], "once, after the transport started")
    }

    @Test func featuresMissingFromTheBuildAreNil() {
        var services = Self.services(peers: nil)
        services.agentLocality = nil
        let app = AppModel(services: services)
        #expect(app.friends == nil)
        #expect(app.makePairing() == nil)
        #expect(app.agentCard == nil)
        #expect(app.link == nil)
    }

    @Test func startLoadsRulesSettingsAndFriends() async {
        let maya = Fixtures.peer("Maya")
        let app = AppModel(services: Self.services(peers: InMemoryPairedPeerStore([maya])))
        await app.start()
        #expect(app.rulesEditor.phase == .writing)
        #expect(app.settings.isLoaded)
        #expect(app.lifecycle.isLoaded)
        #expect(app.friends?.friends == [maya])
    }

    /// A proposal reaching Home posts a notification; a hidden invitee
    /// request does not.
    @Test func lifecycleChangesNotifyOnlyWhenTheyNeedTheOwner() async throws {
        let built = Built()
        let notifier = RecordingNotifier()
        let maya = Fixtures.peer("Maya")
        let app = AppModel(services: Self.services(peers: InMemoryPairedPeerStore([maya]), built: built, notifier: notifier))
        await app.start()
        let down = try #require(built.services.first)
        let id = InteractionID()
        await down.emit(.incoming(id, conversation: ConversationID(), from: maya.id, chainedFrom: nil))
        await eventually { app.lifecycle.interaction(id) != nil }
        #expect(app.home.isEmpty)
        let me = try #require(app.localPeer)
        let proposal = SkillProposal(revision: 1, participants: [me, maya.id], terms: try Terms([.activity: .keywords([try Keyword("boba")])]))
        await down.emit(.lifecycle(id, .proposalReady(proposal)))
        await eventually { app.home.needsYou.count == 1 }
        for _ in 0..<2000 where await notifier.posted.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await notifier.posted.map(\.title) == ["You and Maya are both down for boba"])
    }

    /// Unpairing forgets the friend's card, contact link, and close-friend mark.
    @Test func unpairingForgetsWhatStarlingKeptAboutAFriend() async throws {
        let maya = Fixtures.peer("Maya")
        let app = AppModel(services: Self.services(peers: InMemoryPairedPeerStore([maya])))
        await app.start()
        await app.settings.setClose(maya.id, true)
        app.notes.link(maya.id, to: ContactLink(contactID: "c", name: "Maya", phone: "1"))
        await app.unpair(maya.id)
        #expect(app.friends?.friends.isEmpty == true)
        #expect(!app.settings.isClose(maya.id))
        #expect(app.notes.contactLinks.isEmpty)
    }

    /// Re-review of PR #54, finding 4: at launch the sequence store keeps
    /// numbers for live and recently ended interactions only.
    @Test func launchKeepsSequenceNumbersForResumableConversationsOnly() async throws {
        let file = JSONFile(url: FileManager.default.temporaryDirectory.appending(path: "starling-seq-\(UUID().uuidString).json"))
        let sequences = FileSentSequenceStore(file: file)
        let peer = PeerID.random()
        var live = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [.random()], createdAt: Timestamp(Date()))
        try live.apply(.started, at: Timestamp(Date()))
        var old = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [.random()], createdAt: Timestamp(Date().addingTimeInterval(-3 * 86_400)))
        try old.apply(.withdrawn, at: Timestamp(Date().addingTimeInterval(-2 * 86_400)))
        let hello = ConversationID()
        try sequences.recordSent(1, in: live.conversation, to: peer)
        try sequences.recordSent(2, in: old.conversation, to: peer)
        try sequences.recordSent(3, in: hello, to: peer)

        var services = Self.services()
        services.interactions = InMemoryInteractionStore([live, old])
        services.sequences = sequences
        let app = AppModel(services: services)
        await app.start()
        #expect(sequences.highestSent(in: live.conversation, to: peer) == 1)
        #expect(sequences.highestSent(in: old.conversation, to: peer) == nil)
        #expect(sequences.highestSent(in: hello, to: peer) == nil)
    }

    /// ADR 0021: an interaction that ends retires its conversation, so
    /// nothing is sent in it again.
    @Test func anEndingRetiresItsConversation() async throws {
        let ledger = InMemoryConversationLedger()
        var services = Self.services()
        services.ledger = ledger
        let app = AppModel(services: services)
        await app.start()
        let request = SkillRequest(
            interaction: InteractionID(), conversation: ConversationID(),
            intent: SkillIntent(skill: SampleSkills.downFor.ref, rules: .empty, audience: .allFriends, mode: .askQuietly, expiresAt: Timestamp(Date().addingTimeInterval(3600))),
            participants: [.random()]
        )
        try await app.lifecycle.start(request, settings: app.settings.skillSettings)
        #expect(try await !ledger.isRetired(request.conversation))
        await app.lifecycle.withdraw(request.interaction)
        for _ in 0..<2000 where try await !ledger.isRetired(request.conversation) { try await Task.sleep(for: .milliseconds(1)) }
        #expect(try await ledger.isRetired(request.conversation))
    }

    @Test func anUnreadableLedgerIsReportedOnHome() async throws {
        var services = Self.services()
        services.ledger = UnavailableConversationLedger()
        let app = AppModel(services: services)
        await app.start()
        #expect(app.ledgerNotice != nil)
    }

    /// P15-E request 4.6: a chained Pick a place that agrees on a place
    /// moves the parent plan there.
    @Test func aChainedPlaceMovesTheParentPlan() async throws {
        let maya = Fixtures.peer("Maya")
        let transport = RecordingTransport()
        let me = transport.localPeer
        var parent = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya.id], createdAt: Timestamp(Date()))
        let proposal = SkillProposal(revision: 1, participants: [me, maya.id], terms: try Terms([.activity: .keywords([try Keyword("boba")])]))
        for event: InteractionEvent in [.started, .proposalReady(proposal), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try parent.apply(event, at: Timestamp(Date()))
        }
        parent.record(.plan(try Plan(origin: parent.conversation, attendees: Attendees([me, maya.id]), activity: Keyword("boba"), time: nil)))
        let pick = ScriptedSkillService(descriptor: SampleSkills.pickAPlace)
        var services = Self.services(peers: InMemoryPairedPeerStore([maya]), transport: transport)
        services.makeSkills = { _ in [pick] }
        services.interactions = InMemoryInteractionStore([parent])
        let app = AppModel(services: services)
        await app.start()

        let link = ChainLink(parent: parent.id, parentConversation: parent.conversation, consumed: [.plan], trigger: .atConfirm, optedInAt: Timestamp(Date()))
        let request = SkillRequest(
            interaction: InteractionID(), conversation: ConversationID(),
            intent: SkillIntent(skill: SampleSkills.pickAPlace.ref, rules: .empty, audience: .picked([maya.id]), mode: .invite, expiresAt: Timestamp(Date().addingTimeInterval(3600))),
            participants: [maya.id], chainedFrom: parent.conversation
        )
        let id = try await app.lifecycle.start(request, chain: link, settings: app.settings.skillSettings)
        let place = try PlaceChoice(name: PlaceName("Boba Guys"))
        let offer = SkillProposal(revision: 1, participants: [me, maya.id], terms: try Terms([.place: .places([place])]))
        await pick.emit(.lifecycle(id, .proposalReady(offer)))
        await eventually { app.lifecycle.interaction(id)?.state == .proposed }
        await app.lifecycle.answer(id, with: .accept(proposal: 1))
        await pick.emit(.lifecycle(id, .everyoneConfirmed(revision: 1)))
        await pick.emit(.produced(id, .placeChoice(place)))
        await eventually { app.lifecycle.interaction(parent.id)?.plan?.place == place }
        #expect(app.lifecycle.interaction(parent.id)?.plan?.place == place)
        #expect(app.lifecycle.interaction(parent.id)?.state == .planned)
    }

    @Test func keepItGoingHidesChainsAFriendCannotRun() async throws {
        let maya = Fixtures.peer("Maya")
        let pick = ScriptedSkillService(descriptor: SampleSkills.pickAPlace)
        let transport = RecordingTransport()
        let me = transport.localPeer
        var planned = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [maya.id], createdAt: Timestamp(Date()))
        let proposal = SkillProposal(revision: 1, participants: [me, maya.id], terms: try Terms([.activity: .keywords([try Keyword("boba")])]))
        for event: InteractionEvent in [.started, .proposalReady(proposal), .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1)] {
            try planned.apply(event, at: Timestamp(Date()))
        }
        planned.record(.plan(try Plan(origin: planned.conversation, attendees: Attendees([me, maya.id]), activity: Keyword("boba"), time: nil)))
        var services = Self.services(peers: InMemoryPairedPeerStore([maya]), transport: transport)
        services.makeSkills = { _ in [ScriptedSkillService(descriptor: SampleSkills.downFor), pick] }
        services.interactions = InMemoryInteractionStore([planned])
        let (inbox, continuation) = AsyncStream.makeStream(of: InboxEvent.self)
        services.inboxEvents = inbox
        let app = AppModel(services: services)
        await app.start()
        // No card from Maya yet: nothing is offered.
        #expect(app.chainSuggestions(after: planned).isEmpty)

        func hello(_ skills: [SkillRef]) throws -> InboxEvent {
            .message(try Envelope(conversation: ConversationID(), sender: maya.id, recipient: me, sequence: 0, sentAt: Timestamp(Date()),
                                  body: .hello(AgentCard.forBuild(skills: skills, usesPSI: true, locality: .onDevice))))
        }
        continuation.yield(try hello([SampleSkills.downFor.ref]))
        await eventually { app.cards.card(for: maya.id) != nil }
        #expect(app.chainSuggestions(after: planned).isEmpty)

        continuation.yield(try hello([SampleSkills.downFor.ref, SampleSkills.pickAPlace.ref]))
        await eventually { app.cards.support(of: maya.id, for: SampleSkills.pickAPlace.ref)?.isSupported == true }
        #expect(app.chainSuggestions(after: planned).map(\.id) == [.pickAPlace])
    }
}
