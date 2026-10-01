import Foundation
import StarlingChaining
import StarlingCore
import StarlingFakes
import Testing

/// A store whose reads fail, to check the policy fails closed.
struct BrokenStore: InteractionStore {
    struct Failure: Error {}
    func all() async throws -> [Interaction] { throw Failure() }
    func interaction(_ id: InteractionID) async throws -> Interaction? { throw Failure() }
    func interaction(conversation: ConversationID) async throws -> Interaction? { throw Failure() }
    func save(_ interaction: Interaction) async throws { throw Failure() }
    func remove(_ id: InteractionID) async throws { throw Failure() }
}

@Suite struct ChainedFromPolicyTests {
    static func outbox(policy: any PolicyEngine, transport: RecordingTransport) -> Outbox {
        Outbox(transport: transport, policy: policy, consent: ScriptedConsentProvider(.approved), now: { Fixtures.now })
    }

    static func placeOffer() throws -> MessageBody {
        .propose(try Proposal(round: 0, terms: Terms([.place: .places([Fixtures.place()])])))
    }

    /// A Pick a place link saved after a planned Down for….
    static func savedLink() async throws -> (InMemoryInteractionStore, Interaction, Interaction) {
        let plan = try Fixtures.plannedDownFor()
        let link = try KeepItGoingTests.link(after: plan, reaching: [.started])
        return (InMemoryInteractionStore([plan, link]), plan, link)
    }

    @Test func aLinksEnvelopeMustNameItsParent() async throws {
        let (store, plan, link) = try await Self.savedLink()
        let transport = RecordingTransport(localPeer: Fixtures.me)
        let outbox = Self.outbox(policy: ChainedFromPolicy(wrapping: FixedPolicyEngine(.allow), store: store), transport: transport)

        await #expect(throws: OutboxError.denied(PolicyViolation(rule: ChainedFromPolicy.mismatchRule))) {
            try await outbox.send(Self.placeOffer(), to: Fixtures.maya, conversation: link.conversation, skill: link.skill, mode: .invite)
        }
        await #expect(throws: OutboxError.denied(PolicyViolation(rule: ChainedFromPolicy.mismatchRule))) {
            try await outbox.send(Self.placeOffer(), to: Fixtures.maya, conversation: link.conversation, skill: link.skill, mode: .invite, chainedFrom: ConversationID())
        }
        #expect(await transport.sent.isEmpty)

        let sent = try await outbox.send(Self.placeOffer(), to: Fixtures.maya, conversation: link.conversation, skill: link.skill, mode: .invite, chainedFrom: plan.conversation)
        #expect(sent.chainedFrom == plan.conversation)
        #expect(await transport.sent.count == 1)
    }

    @Test func otherConversationsGoStraightToTheWrappedPolicy() async throws {
        let (store, plan, _) = try await Self.savedLink()
        let base = FixedPolicyEngine(.allow)
        let outbox = Self.outbox(policy: ChainedFromPolicy(wrapping: base, store: store), transport: RecordingTransport(localPeer: Fixtures.me))
        // The plan itself is not a link.
        try await outbox.send(Self.placeOffer(), to: Fixtures.maya, conversation: plan.conversation, skill: plan.skill, mode: .askQuietly)
        // Nor is a conversation this phone has no record of.
        try await outbox.send(Self.placeOffer(), to: Fixtures.maya, conversation: ConversationID())
        #expect(await base.evaluated.count == 2)
    }

    @Test func theWrappedPolicyStillDecides() async throws {
        let (store, plan, link) = try await Self.savedLink()
        let never = PolicyViolation(rule: "disclosure.never", issue: .place)
        let outbox = Self.outbox(policy: ChainedFromPolicy(wrapping: FixedPolicyEngine(.deny(never)), store: store),
                                 transport: RecordingTransport(localPeer: Fixtures.me))
        await #expect(throws: OutboxError.denied(never)) {
            try await outbox.send(Self.placeOffer(), to: Fixtures.maya, conversation: link.conversation, skill: link.skill, mode: .invite, chainedFrom: plan.conversation)
        }
    }

    @Test func aStoreFailureDeniesTheSend() async throws {
        let outbox = Self.outbox(policy: ChainedFromPolicy(wrapping: FixedPolicyEngine(.allow), store: BrokenStore()),
                                 transport: RecordingTransport(localPeer: Fixtures.me))
        await #expect(throws: OutboxError.denied(PolicyViolation(rule: ChainedFromPolicy.storeUnavailableRule))) {
            try await outbox.send(Self.placeOffer(), to: Fixtures.maya, conversation: ConversationID())
        }
    }

    @Test func theAuditStillGetsTheWrappedPolicysItems() async throws {
        let (store, _, _) = try await Self.savedLink()
        let explained = Disclosure(recipient: Fixtures.maya, recipientModel: nil, items: [DisclosedItem(category: .terms, issue: .place, value: nil)])
        let policy = ChainedFromPolicy(wrapping: FixedPolicyEngine(.allow, explain: { _ in explained }), store: store)
        let envelope = try Envelope(conversation: ConversationID(), sender: Fixtures.me, recipient: Fixtures.maya, sequence: 0,
                                    sentAt: Timestamp(Fixtures.now), body: Self.placeOffer())
        let message = OutboundMessage(envelope: envelope, recipientCard: nil, transport: .loopback)
        #expect(try await policy.disclosedItems(for: message) == explained.items)
        // A wrapped policy that cannot say still cannot say.
        await #expect(throws: DisclosureUnavailable()) {
            try await ChainedFromPolicy(wrapping: FixedPolicyEngine(.allow), store: store).disclosedItems(for: message)
        }
    }
}
