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
        let down = ScriptedDownService()
        let maya = Fixtures.peer("Maya")
        let app: AppModel

        init(saved: OwnerRules? = nil) {
            let down = down
            app = AppModel(services: AppServices(
                agent: nil,
                rules: InMemoryRulesStore(saved.map { SavedRules(rules: $0, savedAt: Fixtures.noon) }),
                peers: InMemoryPairedPeerStore([maya]),
                makeDownService: { _ in down },
                pairing: nil,
                makePolicy: factory.make,
                auditLog: observer,
                transport: transport,
                presentConsent: { disclosure in
                    ConsentPresentation(rows: [DisplayLine(title: "G row", detail: "\(disclosure.items.count) items")], recipientModel: "G model", notices: ["G notice"])
                },
                notifier: RecordingNotifier(),
                localNetwork: CountingPrompter()
            ))
        }

        func send() async throws {
            try await app.outbox!.send(.propose(try Proposal(round: 0, terms: .empty)), to: maya.id, conversation: ConversationID())
        }
    }

    static let neverPlace = OwnerRules(constraints: .empty, disclosure: [DisclosureRule(issue: .place, action: .never)])

    @Test func noOutboxWithoutATransport() {
        var services = AppModelTests.services(down: nil, peers: nil)
        services.transport = nil
        #expect(AppModel(services: services).outbox == nil)
    }

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
        #expect(request.items == [DisplayLine(title: "G row", detail: "0 items")])
        #expect(request.recipientModel == "G model")
        #expect(request.notices == ["G notice"])
        setup.app.consent.answerCurrent(.approved)
        try await send.value

        #expect(await setup.transport.sent.count == 1)
        #expect(await setup.observer.records.count == 1)
    }

    @Test func savedRulesApplyFromLaunch() async throws {
        let setup = Setup(saved: Self.neverPlace)
        await setup.app.start()
        await #expect(throws: OutboxError.denied(PolicyViolation(rule: "never", issue: .place))) { try await setup.send() }
        #expect(await setup.observer.records.isEmpty)
    }

    @Test func savingRulesUpdatesThePolicy() async throws {
        let setup = Setup()
        await setup.app.start()
        setup.app.rulesEditor.editByHand()
        setup.app.rulesEditor.setSharing(.never, for: .place)
        #expect(await setup.app.rulesEditor.save())
        #expect(await setup.app.policy?.rules == Self.neverPlace)
    }

    @Test func anIntentsSharingAppliesWhileItIsOutAndEndsWithIt() async throws {
        let setup = Setup()
        await setup.app.start()
        let down = try #require(setup.app.down)
        await down.editByHand()
        down.setSharing(.never, for: .place)
        await down.goDown()
        #expect(await setup.app.policy?.rules == Self.neverPlace)

        await down.withdraw()
        #expect(await setup.app.policy?.rules == .empty)
    }

    @Test func theIntentPolicyIsInPlaceBeforeTheServiceHearsOfIt() async throws {
        let setup = Setup()
        await setup.app.start()
        let down = try #require(setup.app.down)
        await down.editByHand()
        down.setSharing(.never, for: .place)
        await down.goDown()
        // setIntent ran after the hook, so the policy it could send under
        // already had the intent's rules.
        #expect(await setup.down.intents.count == 1)
        #expect(setup.factory.snapshots.last == Self.neverPlace)
    }
}
