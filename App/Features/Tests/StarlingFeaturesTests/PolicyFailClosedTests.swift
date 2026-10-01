import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

/// A Down service whose clearIntent waits until the test releases it.
actor ClearGatedDownService: DownService {
    nonisolated let events: AsyncStream<DownEvent> = AsyncStream { _ in }
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var isClearing = false
    private(set) var intents: [DownIntent] = []

    func setIntent(_ intent: DownIntent) async throws { intents.append(intent) }
    func clearIntent() async {
        isClearing = true
        await withCheckedContinuation { gate = $0 }
        isClearing = false
    }
    func handle(_ event: InboxEvent) async {}
    func release() {
        gate?.resume()
        gate = nil
    }
}

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

    static func app(down: any DownService, rules: any RulesStore) -> AppModel {
        AppModel(services: AppServices(
            agent: nil,
            rules: rules,
            peers: InMemoryPairedPeerStore(),
            makeDownService: { _ in down },
            makePairingSession: nil,
            makePolicy: EngineFactory().make,
            transport: RecordingTransport(),
            notifier: RecordingNotifier(),
            localNetwork: CountingPrompter()
        ))
    }

    @Test func savedRulesThatCannotCombineWithTheIntentBlockSendsAndEndIt() async throws {
        let service = ClearGatedDownService()
        let app = Self.app(down: service, rules: InMemoryRulesStore())
        await app.start()
        let down = try #require(app.down)
        let policy = try #require(app.policy)

        // Down with a budget limit and "never share place".
        await down.editByHand()
        down.draft.add(.atMost, issue: .budget)
        down.setSharing(.never, for: .place)
        await down.goDown()
        #expect(down.phase == .active)

        // The owner saves eight budget limits: nine no longer fit one topic.
        app.rulesEditor.editByHand()
        for _ in 0..<ConstraintSet.maxConstraintsPerIssue { app.rulesEditor.draft.add(.atMost, issue: .budget) }
        let saving = Task { await app.rulesEditor.save() }
        for _ in 0..<2000 where !(await service.isClearing) { try await Task.sleep(for: .milliseconds(1)) }

        // While the intent is being ended, nothing may go out.
        #expect(await policy.evaluate(try Self.message(to: .random())) == .deny(PolicyViolation(rule: RulesPolicy.blockedRule)))

        await service.release()
        #expect(await saving.value)
        #expect(down.phase == .composing)
        #expect(down.notice?.contains("saved rules changed") == true)
    }
}
