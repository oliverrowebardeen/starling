import Foundation
import StarlingCore
import StarlingFakes
import StarlingPolicy

enum Fixtures {
    static let alice = try! PeerID(bytes: Data(repeating: 1, count: 32))
    static let bob = try! PairedPeer(
        publicKey: IdentityPublicKey(bytes: Data(repeating: 2, count: 32)),
        nickname: "Bob", pairedAt: Timestamp(millisecondsSince1970: 0)
    )
    static let conversation = ConversationID()
    static let queryID = MessageID()
    static let card = try! AgentCard(model: .onDevice, capabilities: [.down])
    static let value = IssueValue.keywords([try! Keyword("boba")])
    static let terms = try! Terms([.activity: value])
    static let frame = try! PSIFrame(session: UUID(), step: 0, payload: Data([1, 2, 3]))
    static let stub = InsecurePSIStub().descriptor

    static func envelope(
        _ body: MessageBody, sender: PeerID = alice, recipient: PeerID = bob.id,
        conversation: ConversationID = conversation, id: MessageID = MessageID()
    ) throws -> Envelope {
        try Envelope(id: id, conversation: conversation, sender: sender, recipient: recipient,
                     sequence: 0, sentAt: Timestamp(Date()), body: body)
    }

    static func outbound(
        _ body: MessageBody, card: AgentCard? = card,
        recipient: PeerID = bob.id, conversation: ConversationID = conversation,
        context: OutboundContext = .empty
    ) throws -> OutboundMessage {
        OutboundMessage(envelope: try envelope(body, recipient: recipient, conversation: conversation),
                        recipientCard: card, transport: .loopback, context: context)
    }

    static func engine(
        action: DisclosureRule.Action? = nil, onlyOnDevice: Bool = false, paired: Bool = true
    ) -> DeterministicPolicyEngine {
        DeterministicPolicyEngine(
            ownerRules: OwnerRules(constraints: .empty, disclosure: action.map {
                [DisclosureRule(issue: .activity, action: $0)]
            } ?? []),
            onlyOnDeviceAgents: onlyOnDevice,
            pairedPeers: InMemoryPairedPeerStore(paired ? [bob] : [])
        )
    }

    static func psiContext(privatePSI: Bool = false, inputs: [IssueKey: IssueValue] = terms.values) -> OutboundContext {
        OutboundContext(psi: .init(
            provider: privatePSI ? PSIProviderDescriptor(name: "test-private", isPrivate: true) : stub,
            inputs: inputs
        ))
    }

    static func body(_ kind: MessageBody.Kind) throws -> MessageBody {
        switch kind {
        case .hello: .hello(card)
        case .propose: .propose(try Proposal(round: 0, terms: terms))
        case .counter: .counter(try Proposal(round: 1, terms: terms, inReplyTo: queryID))
        case .accept: .accept(Acceptance(proposal: queryID, terms: terms))
        case .reject: .reject(Rejection(proposal: queryID, reason: .noOverlap))
        case .query: .query(try Query(issue: .activity, candidates: value))
        case .answer: .answer(try Answer(query: queryID, issue: .activity, status: .answered, acceptable: value))
        case .psi: .psi(frame)
        }
    }
}
