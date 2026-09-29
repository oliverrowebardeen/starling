import Foundation

// MARK: - Envelope

/// The unit every transport carries (after encoding, and in Phase 1 after
/// sealing by the secure channel).
///
/// Build envelopes with `Outbox`, which assigns `id`, `sender`, `sequence`, and
/// `sentAt`, so callers cannot forge them.
public struct Envelope: Hashable, Sendable, Codable {
    public static let currentVersion: UInt16 = 0

    public let version: UInt16
    public let id: MessageID
    public let conversation: ConversationID
    public let sender: PeerID
    public let recipient: PeerID
    /// Unique and increasing per `(sender, conversation)`, starting at 0.
    /// Gaps are allowed. `Inbox` rejects duplicates and anything more than
    /// `Inbox.replayWindow` below the highest value it has accepted.
    public let sequence: UInt64
    public let sentAt: Timestamp
    public let body: MessageBody

    public init(
        version: UInt16 = Envelope.currentVersion,
        id: MessageID = MessageID(),
        conversation: ConversationID,
        sender: PeerID,
        recipient: PeerID,
        sequence: UInt64,
        sentAt: Timestamp,
        body: MessageBody
    ) throws {
        guard sender != recipient else { throw ValidationError("Envelope", "sender equals recipient") }
        self.version = version
        self.id = id
        self.conversation = conversation
        self.sender = sender
        self.recipient = recipient
        self.sequence = sequence
        self.sentAt = sentAt
        self.body = body
    }

    private enum CodingKeys: String, CodingKey { case version, id, conversation, sender, recipient, sequence, sentAt, body }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: c.decode(UInt16.self, forKey: .version),
            id: c.decode(MessageID.self, forKey: .id),
            conversation: c.decode(ConversationID.self, forKey: .conversation),
            sender: c.decode(PeerID.self, forKey: .sender),
            recipient: c.decode(PeerID.self, forKey: .recipient),
            sequence: c.decode(UInt64.self, forKey: .sequence),
            sentAt: c.decode(Timestamp.self, forKey: .sentAt),
            body: c.decode(MessageBody.self, forKey: .body)
        )
    }
}

// MARK: - Message body

/// Typed performatives. There is deliberately no free-text case: a peer can
/// only send bounded, validated values (brief 3.5).
public enum MessageBody: Hashable, Sendable {
    /// First message on a new link: who I am and what my agent can do.
    case hello(AgentCard)
    case propose(Proposal)
    case counter(Proposal)
    case accept(Acceptance)
    case reject(Rejection)
    /// "Which of these candidates are acceptable to you?"
    case query(Query)
    case answer(Answer)
    /// An opaque step of a private set intersection run.
    case psi(PSIFrame)

    public var kind: Kind {
        switch self {
        case .hello: .hello
        case .propose: .propose
        case .counter: .counter
        case .accept: .accept
        case .reject: .reject
        case .query: .query
        case .answer: .answer
        case .psi: .psi
        }
    }

    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case hello, propose, counter, accept, reject, query, answer, psi
    }
}

extension MessageBody: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .hello: self = .hello(try c.decode(AgentCard.self, forKey: .value))
        case .propose: self = .propose(try c.decode(Proposal.self, forKey: .value))
        case .counter: self = .counter(try c.decode(Proposal.self, forKey: .value))
        case .accept: self = .accept(try c.decode(Acceptance.self, forKey: .value))
        case .reject: self = .reject(try c.decode(Rejection.self, forKey: .value))
        case .query: self = .query(try c.decode(Query.self, forKey: .value))
        case .answer: self = .answer(try c.decode(Answer.self, forKey: .value))
        case .psi: self = .psi(try c.decode(PSIFrame.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .type)
        switch self {
        case .hello(let v): try c.encode(v, forKey: .value)
        case .propose(let v), .counter(let v): try c.encode(v, forKey: .value)
        case .accept(let v): try c.encode(v, forKey: .value)
        case .reject(let v): try c.encode(v, forKey: .value)
        case .query(let v): try c.encode(v, forKey: .value)
        case .answer(let v): try c.encode(v, forKey: .value)
        case .psi(let v): try c.encode(v, forKey: .value)
        }
    }
}

// MARK: - Payloads

public struct Proposal: Hashable, Sendable, Codable {
    /// 0 for the opening offer, then +1 per counter. Bounded so a peer cannot
    /// keep a negotiation (and the model) busy forever.
    public let round: UInt16
    public let terms: Terms
    /// The proposal this one answers, if it is a counter.
    public let inReplyTo: MessageID?
    public let expiresAt: Timestamp?

    public init(round: UInt16, terms: Terms, inReplyTo: MessageID? = nil, expiresAt: Timestamp? = nil) throws {
        guard round < ProtocolLimits.maxNegotiationRounds else {
            throw ValidationError("Proposal.round", "exceeds \(ProtocolLimits.maxNegotiationRounds)")
        }
        self.round = round
        self.terms = terms
        self.inReplyTo = inReplyTo
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey { case round, terms, inReplyTo, expiresAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            round: c.decode(UInt16.self, forKey: .round),
            terms: c.decode(Terms.self, forKey: .terms),
            inReplyTo: c.decodeIfPresent(MessageID.self, forKey: .inReplyTo),
            expiresAt: c.decodeIfPresent(Timestamp.self, forKey: .expiresAt)
        )
    }
}

public struct Acceptance: Hashable, Sendable, Codable {
    public let proposal: MessageID
    /// The exact terms being accepted, so both sides can confirm they agree.
    public let terms: Terms

    public init(proposal: MessageID, terms: Terms) {
        self.proposal = proposal
        self.terms = terms
    }
}

public struct Rejection: Hashable, Sendable, Codable {
    public enum Reason: String, Hashable, Sendable, Codable {
        case noOverlap, declinedByOwner, expired, policy, tooManyRounds, unsupported
    }

    public let proposal: MessageID
    public let reason: Reason

    public init(proposal: MessageID, reason: Reason) {
        self.proposal = proposal
        self.reason = reason
    }
}

/// Ask which of `candidates` are acceptable for `issue`. The answer reveals
/// only the acceptable subset, never the underlying data (private query,
/// brief 2.7).
public struct Query: Hashable, Sendable, Codable {
    public let issue: IssueKey
    public let candidates: IssueValue

    public init(issue: IssueKey, candidates: IssueValue) throws {
        self.issue = issue
        self.candidates = try candidates.validated()
    }

    private enum CodingKeys: String, CodingKey { case issue, candidates }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(issue: c.decode(IssueKey.self, forKey: .issue), candidates: c.decode(IssueValue.self, forKey: .candidates))
    }
}

public struct Answer: Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable {
        case answered
        /// The owner or policy declined to answer.
        case declined
        /// The agent asked its owner; a later answer will follow.
        case pendingOwner
    }

    public let query: MessageID
    public let status: Status
    /// Present only when `status == .answered`.
    public let acceptable: IssueValue?

    public init(query: MessageID, status: Status, acceptable: IssueValue? = nil) throws {
        guard (status == .answered) == (acceptable != nil) else {
            throw ValidationError("Answer", "acceptable must be present exactly when status is answered")
        }
        self.query = query
        self.status = status
        self.acceptable = try acceptable?.validated()
    }

    private enum CodingKeys: String, CodingKey { case query, status, acceptable }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            query: c.decode(MessageID.self, forKey: .query),
            status: c.decode(Status.self, forKey: .status),
            acceptable: c.decodeIfPresent(IssueValue.self, forKey: .acceptable)
        )
    }
}

public struct PSIFrame: Hashable, Sendable, Codable {
    public let session: UUID
    public let step: UInt8
    public let payload: Data

    public init(session: UUID, step: UInt8, payload: Data) throws {
        guard payload.count <= ProtocolLimits.maxPSIPayloadBytes else {
            throw ValidationError("PSIFrame", "payload larger than \(ProtocolLimits.maxPSIPayloadBytes) bytes")
        }
        self.session = session
        self.step = step
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey { case session, step, payload }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            session: c.decode(UUID.self, forKey: .session),
            step: c.decode(UInt8.self, forKey: .step),
            payload: c.decode(Data.self, forKey: .payload)
        )
    }
}

// MARK: - Agent card

/// Where an agent's model runs. Declared on the agent card so owners can set
/// policies such as "only negotiate with on-device agents" (brief 3.7).
public enum ModelLocality: Hashable, Sendable {
    case onDevice
    case privateCloudCompute
    /// A named third-party provider, for example "anthropic".
    case thirdPartyCloud(provider: String)
    /// Rule-based agent with no language model.
    case none

    public func validated() throws -> ModelLocality {
        if case .thirdPartyCloud(let provider) = self {
            let scalars = provider.unicodeScalars
            guard (1...ProtocolLimits.maxProviderNameCharacters).contains(scalars.count),
                  scalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
            else { throw ValidationError("ModelLocality.provider", "must be 1-32 of a-z 0-9 -") }
        }
        return self
    }
}

extension ModelLocality: Codable {
    private enum CodingKeys: String, CodingKey { case type, provider }
    private enum Kind: String, Codable { case onDevice, privateCloudCompute, thirdPartyCloud, none }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .onDevice: self = .onDevice
        case .privateCloudCompute: self = .privateCloudCompute
        case .none: self = .none
        case .thirdPartyCloud: self = try ModelLocality.thirdPartyCloud(provider: c.decode(String.self, forKey: .provider)).validated()
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch try validated() {
        case .onDevice: try c.encode(Kind.onDevice, forKey: .type)
        case .privateCloudCompute: try c.encode(Kind.privateCloudCompute, forKey: .type)
        case .none: try c.encode(Kind.none, forKey: .type)
        case .thirdPartyCloud(let provider):
            try c.encode(Kind.thirdPartyCloud, forKey: .type)
            try c.encode(provider, forKey: .provider)
        }
    }
}

/// How much to trust a peer's `ModelLocality`. Only `selfDeclared` exists
/// until brief open question 4 is answered; the UI must say so.
public enum LocalityEvidence: String, Hashable, Sendable, Codable {
    case selfDeclared
}

/// A named feature an agent supports. Unknown capabilities decode fine, so
/// newer peers do not break older ones.
public struct Capability: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        // Same format as IssueKey.
        _ = try IssueKey(rawValue)
        self.rawValue = rawValue
    }

    private init(known: String) { rawValue = known }

    public static let down = Capability(known: "down")
    public static let scheduling = Capability(known: "scheduling")
    public static let groupDecision = Capability(known: "group_decision")
    public static let psi = Capability(known: "psi")

    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

public struct AgentCard: Hashable, Sendable, Codable {
    public let protocolVersions: [UInt16]
    public let model: ModelLocality
    public let localityEvidence: LocalityEvidence
    public let capabilities: [Capability]

    public init(
        protocolVersions: [UInt16] = [Envelope.currentVersion],
        model: ModelLocality,
        localityEvidence: LocalityEvidence = .selfDeclared,
        capabilities: [Capability]
    ) throws {
        guard (1...ProtocolLimits.maxProtocolVersionsAdvertised).contains(protocolVersions.count) else {
            throw ValidationError("AgentCard.protocolVersions", "must list 1-\(ProtocolLimits.maxProtocolVersionsAdvertised) versions")
        }
        guard capabilities.count <= ProtocolLimits.maxCapabilities else {
            throw ValidationError("AgentCard.capabilities", "too many")
        }
        self.protocolVersions = protocolVersions
        self.model = try model.validated()
        self.localityEvidence = localityEvidence
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey { case protocolVersions, model, localityEvidence, capabilities }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersions: c.decode([UInt16].self, forKey: .protocolVersions),
            model: c.decode(ModelLocality.self, forKey: .model),
            localityEvidence: c.decode(LocalityEvidence.self, forKey: .localityEvidence),
            capabilities: c.decode([Capability].self, forKey: .capabilities)
        )
    }
}
