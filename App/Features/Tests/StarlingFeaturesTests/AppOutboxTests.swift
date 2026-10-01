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
                describeEgress: { envelope, _ in
                    guard case .propose(let proposal) = envelope.body else { return [] }
                    return proposal.terms.values.keys.sorted().map { DisclosedItem(category: .terms, issue: $0, value: proposal.terms.values[$0]) }
                },
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
            intent: SkillIntent(skill: SampleSkills.downFor.ref, rules: .empty, audience: .allFriends, expiresAt: Timestamp(Date().addingTimeInterval(3600))),
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
