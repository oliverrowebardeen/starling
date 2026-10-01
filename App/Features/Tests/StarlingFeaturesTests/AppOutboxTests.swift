import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

@MainActor
@Suite struct AppOutboxTests {
    @MainActor
    struct Setup {
        let factory = EngineFactory()
        let transport = RecordingTransport()
        let observer = RecordingOutboxObserver()
        let maya = Fixtures.peer("Maya")
        let down = ScriptedSkillService(descriptor: SampleSkills.downFor)
        let app: AppModel

        init(saved: OwnerRules? = nil, settings: OwnerSettings? = nil) {
            let factory = factory
            let down = down
            app = AppModel(services: AppServices(
                registry: SampleSkills.registry,
                makeSkills: { _ in [down] },
                interactions: InMemoryInteractionStore(),
                settings: InMemoryOwnerSettingsStore(settings),
                rules: InMemoryRulesStore(saved.map { SavedRules(rules: $0, savedAt: Fixtures.noon) }),
                peers: InMemoryPairedPeerStore([maya]),
                makePolicy: { rules, _ in factory.make(rules) },
                auditLog: observer,
                transport: transport,
                presentConsent: { disclosure in
                    ConsentPresentation(rows: disclosure.items.map { _ in DisplayLine(title: "G row", detail: nil) }, recipientModel: "G model", notices: ["G notice"])
                },
                notifier: RecordingNotifier(),
                localNetwork: CountingPrompter()
            ))
        }

        func send(conversation: ConversationID = ConversationID(), terms: Terms = .empty) async throws {
            try await app.outbox!.send(.propose(try Proposal(round: 0, terms: terms)), to: maya.id, conversation: conversation)
        }
    }

    static let neverPlace = DisclosureRule(issue: .place, action: .never)

    @Test func sendsBeforeStartAreDenied() async throws {
        let setup = Setup()
        await #expect(throws: OutboxError.denied(PolicyViolation(rule: RulesPolicy.notLoadedRule))) { try await setup.send() }
        #expect(await setup.transport.sent.isEmpty)
    }

    @Test func sendsGoThroughPolicyConsentSheetAndAuditLog() async throws {
        let setup = Setup()
        await setup.app.start()
        let send = Task { try await setup.send() }
        await eventually { setup.app.consent.current != nil }
        let request = try #require(setup.app.consent.current)
        #expect(request.recipientModel == "G model")
        #expect(request.notices == ["G notice"])
        setup.app.consent.answerCurrent(.approved)
        try await send.value
        #expect(await setup.transport.sent.count == 1)
        #expect(await setup.observer.records.count == 1)
    }

    /// ADR 0014: privacy topics are the standing sharing, from launch.
    @Test func topicsApplyFromLaunchAndFollowChanges() async throws {
        var settings = OwnerSettings()
        try settings.privacy.set(.never, for: .place)
        let setup = Setup(settings: settings)
        await setup.app.start()
        #expect(await setup.app.policy?.rules?.disclosure.contains(Self.neverPlace) == true)
        await #expect(throws: OutboxError.denied(PolicyViolation(rule: "never", issue: .place))) { try await setup.send() }

        await setup.app.settings.set(.askMe, for: .place)
        #expect(await setup.app.policy?.rules?.disclosure.contains(DisclosureRule(issue: .place, action: .askEachTime)) == true)
    }

    /// Phase 1's saved "never share place" becomes Place: Never on the first
    /// Phase 1.5 launch, and saved constraints still apply.
    @Test func phaseOneSharingMigratesIntoTopics() async throws {
        let saved = OwnerRules(constraints: try ConstraintSet([.budget: [try Constraint(.atMost(try MoneyAmount(minorUnits: 1500)))]]), disclosure: [Self.neverPlace])
        let setup = Setup(saved: saved)
        await setup.app.start()
        #expect(setup.app.settings.choice(for: .place) == .never)
        let rules = try #require(await setup.app.policy?.rules)
        #expect(rules.constraints == saved.constraints)
        #expect(rules.disclosure == setup.app.settings.settings.privacy.disclosureRules)
    }

    /// Final review of PR #54, finding 1: a restrictive change governs
    /// sends while its write is still in flight; a loosening waits for it.
    @Test func aRestrictiveChangeGovernsSendsBeforeItsWriteFinishes() async throws {
        var start = OwnerSettings()
        try start.privacy.set(.share, for: .place)
        let store = GatedSettingsStore(start)
        let factory = EngineFactory()
        let transport = RecordingTransport()
        let maya = Fixtures.peer("Maya")
        let app = AppModel(services: AppServices(
            registry: SampleSkills.registry, interactions: InMemoryInteractionStore(), settings: store,
            rules: InMemoryRulesStore(), peers: InMemoryPairedPeerStore([maya]),
            makePolicy: { rules, _ in factory.make(rules) }, transport: transport,
            notifier: RecordingNotifier(), localNetwork: CountingPrompter()
        ))
        await app.start()
        let policy = try #require(app.policy)
        let message = try PolicyFailClosedTests.message(to: maya.id)
        guard case .needsConsent = await policy.evaluate(message) else { Issue.record("expected Share to apply"); return }

        await store.block()
        let tightening = Task { await app.settings.set(.never, for: .place) }
        for _ in 0..<2000 where await store.waiting == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await policy.evaluate(message) == .deny(PolicyViolation(rule: "never", issue: .place)), "Never applies before the write returns")
        await store.release()
        await tightening.value

        await store.block()
        let loosening = Task { await app.settings.set(.share, for: .place) }
        for _ in 0..<2000 where await store.waiting == 0 { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await policy.evaluate(message) == .deny(PolicyViolation(rule: "never", issue: .place)), "a loosening waits for its save")
        await store.release()
        await loosening.value
        guard case .needsConsent = await policy.evaluate(message) else { Issue.record("expected Share after the save"); return }
    }

    /// ADR 0021 amendment 12: once a stricter policy is installed, a send
    /// cleared under the looser one and still waiting never leaves.
    @Test func tighteningCancelsSendsStillWaiting() async throws {
        var start = OwnerSettings()
        try start.privacy.set(.share, for: .place)
        let transport = HoldingTransport()
        let maya = Fixtures.peer("Maya")
        let app = AppModel(services: AppServices(
            registry: SampleSkills.registry, interactions: InMemoryInteractionStore(), settings: GatedSettingsStore(start),
            rules: InMemoryRulesStore(), peers: InMemoryPairedPeerStore([maya]),
            makePolicy: { _, _ in FixedPolicyEngine(.allow) }, transport: transport,
            notifier: RecordingNotifier(), localNetwork: CountingPrompter()
        ))
        await app.start()
        let outbox = try #require(app.outbox)
        let conversation = ConversationID()
        // The first send holds in the transport; the second waits behind it.
        let first = Task { try await outbox.send(.propose(try Proposal(round: 0, terms: .empty)), to: maya.id, conversation: conversation) }
        for _ in 0..<2000 where await transport.waiting == 0 { try await Task.sleep(for: .milliseconds(1)) }
        let second = Task { try await outbox.send(.propose(try Proposal(round: 1, terms: .empty)), to: maya.id, conversation: conversation) }
        try await Task.sleep(for: .milliseconds(30))

        await app.settings.set(.never, for: .place)
        await transport.release()
        await #expect(throws: (any Error).self) { try await first.value }
        await #expect(throws: (any Error).self) { try await second.value }
        #expect(await transport.delivered.isEmpty)
    }

    @Test func theOnDeviceOnlyChoiceReachesThePolicy() async throws {
        let setup = Setup()
        await setup.app.start()
        await setup.app.settings.setOnlyOnDeviceAgents(true)
        #expect(await setup.app.policy?.onlyOnDeviceAgents == true)
    }

    /// "What left your phone" records what each send disclosed on its
    /// interaction: the sheet's items when asked, the policy's otherwise.
    @Test func everySendIsRecordedOnItsInteraction() async throws {
        let setup = Setup()
        await setup.app.start()
        let request = SkillRequest(
            interaction: InteractionID(), conversation: ConversationID(),
            intent: SkillIntent(skill: SampleSkills.downFor.ref, rules: .empty, audience: .allFriends, mode: SampleSkills.downFor.defaultSendMode, expiresAt: Timestamp(Date().addingTimeInterval(3600))),
            participants: [setup.maya.id]
        )
        try await setup.app.lifecycle.start(request, settings: setup.app.settings.skillSettings)
        let terms = try Terms([.activity: .keywords([try Keyword("boba")])])
        let send = Task { try await setup.send(conversation: request.conversation, terms: terms) }
        await eventually { setup.app.consent.current != nil }
        #expect(setup.app.lifecycle.interaction(request.interaction)?.state == .awaitingConsent(resume: .negotiating))
        setup.app.consent.answerCurrent(.approved)
        try await send.value
        await eventually { setup.app.lifecycle.interaction(request.interaction)?.egress.isEmpty == false }
        let interaction = try #require(setup.app.lifecycle.interaction(request.interaction))
        #expect(interaction.state == .negotiating)
        #expect(interaction.egress.count == 1)
        #expect(interaction.egress.first?.recipient == setup.maya.id)
    }
}

/// A transport that holds every send until released, then delivers it
/// unless the send was cancelled meanwhile.
actor HoldingTransport: Transport {
    nonisolated let kind = TransportKind.loopback
    nonisolated let localPeer = PeerID.random()
    nonisolated let events: AsyncStream<TransportEvent> = AsyncStream { _ in }
    private var released = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var delivered: [Frame] = []
    var waiting: Int { held.count }

    func release() {
        released = true
        held.forEach { $0.resume() }
        held = []
    }

    func start() async throws {}
    func stop() async {}

    func send(_ frame: Frame, to peer: PeerID) async throws {
        if !released { await withCheckedContinuation { held.append($0) } }
        try Task.checkCancellation()
        delivered.append(frame)
    }
}
