import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

@Suite struct SharingMergeTests {
    /// Re-review finding 1 on PR #27: sharing merges on its own and cannot fail.
    @Test func sharingMergesWithoutConstraints() {
        let merged = RulesMerge.sharing(
            intent: [DisclosureRule(issue: .place, action: .never), DisclosureRule(issue: .time, action: .allowOnDevicePeers)],
            standing: [DisclosureRule(issue: .place, action: .allowOnDevicePeers), DisclosureRule(issue: .time, action: .askEachTime)]
        )
        #expect(merged == [DisclosureRule(issue: .place, action: .never), DisclosureRule(issue: .time, action: .askEachTime)])
    }
}

/// Review findings 1 and 2 on PR #27: the policy fails closed.
@MainActor
@Suite struct PolicyFailClosedTests {
    static func message(to peer: PeerID) throws -> OutboundMessage {
        let envelope = try Envelope(conversation: ConversationID(), sender: .random(), recipient: peer, sequence: 0,
                                    sentAt: Timestamp(Fixtures.noon), body: .propose(try Proposal(round: 0, terms: .empty)))
        return OutboundMessage(envelope: envelope, recipientCard: nil, transport: .loopback)
    }

    static func app(rules: any RulesStore, settings: any OwnerSettingsStore = InMemoryOwnerSettingsStore()) -> AppModel {
        AppModel(services: AppServices(
            registry: SampleSkills.registry,
            interactions: InMemoryInteractionStore(),
            settings: settings,
            rules: rules,
            peers: InMemoryPairedPeerStore(),
            makePolicy: { rules, _ in EngineFactory().make(rules) },
            transport: RecordingTransport(),
            notifier: RecordingNotifier(),
            localNetwork: CountingPrompter()
        ))
    }

    @Test func aCorruptRulesFileKeepsEverySendDenied() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "starling-\(UUID().uuidString)/rules.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let app = Self.app(rules: FileRulesStore(url: url))
        await app.start()
        let policy = try #require(app.policy)

        #expect(await policy.evaluate(try Self.message(to: .random())) == .deny(PolicyViolation(rule: RulesPolicy.notLoadedRule)))
        #expect(app.rulesEditor.loadFailed)
        #expect(app.rulesEditor.notice?.contains("won't send anything") == true)

        // A topic change cannot unlock it either.
        await app.settings.set(.share, for: .place)
        #expect(await policy.evaluate(try Self.message(to: .random())) == .deny(PolicyViolation(rule: RulesPolicy.notLoadedRule)))

        // Saving rules again replaces the unreadable file and opens the policy.
        app.rulesEditor.editByHand()
        #expect(await app.rulesEditor.save())
        #expect(app.rulesEditor.loadFailed == false)
        guard case .needsConsent = await policy.evaluate(try Self.message(to: .random())) else {
            Issue.record("expected the policy to judge sends again")
            return
        }
    }
}
