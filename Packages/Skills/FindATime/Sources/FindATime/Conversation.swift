import Foundation
import StarlingCore

// The state of one Find a time conversation on this phone. Codable so the
// service can checkpoint it and resume after a restart (ADR 0222). It holds
// candidate times and peer IDs, never anything read from a calendar beyond
// which times are free.

/// The starter's side: offers times, collects answers, proposes, confirms.
struct Initiating: Hashable, Sendable, Codable {
    enum Phase: String, Hashable, Sendable, Codable {
        /// Reading the owner's availability.
        case resolving
        /// Waiting for the owner to say which times work.
        case askingOwner
        /// Queries are out; collecting answers.
        case collecting
        /// A proposal is out; collecting "That works".
        case proposing
        /// Everyone said "That works"; confirmations are going out. The plan
        /// exists only once every one has left the phone.
        case confirming
        /// Every confirmation left. Kept until the plan ends, to replay the
        /// confirmation if a friend did not get it.
        case planned
    }

    /// The service's copy of the lifecycle record, used to emit only events
    /// the coordinator will accept. Replaced by the stored one on restore.
    var interaction: Interaction
    let chainedFrom: ConversationID?
    let expiresAt: Timestamp
    let activity: Keyword?
    /// The owner's limits for this request, checked again before proposing.
    var limits: ConstraintSet = .empty
    /// Friends asked, in the owner's order.
    var invitees: [PeerID]
    var phase: Phase
    /// The times offered to every friend.
    var candidates: [TimeSlot] = []
    /// Each friend's answer: the offered times that work for them (empty
    /// for none, a pass, or a declined consent).
    var answers: [PeerID: [TimeSlot]] = [:]
    /// Friends a query reached the link for. Only they are ever told
    /// "no plan": a friend never asked learns nothing, not even that a
    /// request existed.
    var contacted: Set<PeerID> = []
    var answerDeadline: Timestamp?
    var draft: Draft?
    /// Envelopes of the current proposal sent to each friend, retries included.
    var proposalIDs: [PeerID: Set<MessageID>] = [:]
    /// Friends who said "That works", with the proposal envelope they named.
    var accepted: [PeerID: MessageID] = [:]
    var ownerAccepted = false
    /// Friends whose confirmation has left the phone.
    var confirmed: Set<PeerID> = []
    var confirmDeadline: Timestamp?

    var conversation: ConversationID { interaction.conversation }
    /// Friends still owed a step: unanswered while collecting, not yet
    /// accepted while proposing.
    var waitingOn: [PeerID] {
        switch phase {
        case .collecting: invitees.filter { answers[$0] == nil }
        case .proposing: (draft?.members ?? []).filter { accepted[$0] == nil }
        case .confirming: (draft?.members ?? []).filter { !confirmed.contains($0) }
        default: []
        }
    }
}

/// One proposal: a time, the friends in it, and the terms on the wire.
struct Draft: Hashable, Sendable, Codable {
    let revision: UInt32
    let slot: TimeSlot
    let members: [PeerID]
    let terms: Terms
    let plan: Plan
}

/// The answering side: says which offered times work, then confirms.
struct Invited: Hashable, Sendable, Codable {
    enum Phase: String, Hashable, Sendable, Codable {
        case resolving
        case askingOwner
        /// Answered; waiting for a proposal.
        case answered
        /// A proposal card is up.
        case proposed
        /// The owner said "That works"; waiting for the starter's confirmation.
        case accepted
        case planned
    }

    var interaction: Interaction
    let asker: PeerID
    let chainedFrom: ConversationID?
    let expiresAt: Timestamp
    /// The times the starter offered.
    let candidates: [TimeSlot]
    /// The starter's query as it arrived, passed to the policy with the
    /// answer (`OutboundContext.answering`, ADR 0019).
    var query: Query?
    var lastQuery: MessageID
    var phase: Phase
    /// The owner's standing limits when the request arrived ("no plans
    /// before 10"), checked against every proposal.
    var limits: ConstraintSet = .empty
    /// What this phone told the starter works.
    var answered: [TimeSlot]?
    var offer: Offer?
    /// The proposal revision whose acceptance has left the phone (cleared
    /// policy and consent and reached the link). A confirmation counts only
    /// for it.
    var acceptanceLeft: UInt32?
    /// A confirmation that arrived while the acceptance was still waiting
    /// (on a consent sheet, say). Applied once the acceptance leaves.
    var heldConfirmation: Acceptance?

    var conversation: ConversationID { interaction.conversation }
}

/// A proposal received from the starter.
struct Offer: Hashable, Sendable, Codable {
    let round: UInt16
    let terms: Terms
    /// The proposal as it arrived, passed to the policy with this phone's
    /// acceptance (`OutboundContext.accepting`, ADR 0019 amendment 10).
    var proposal: Proposal?
    /// Envelopes carrying these terms (the first and any retries).
    var ids: Set<MessageID>
    var latest: MessageID
    /// This phone's revision for the proposal card.
    let revision: UInt32
    let plan: Plan
}

/// One interaction's saved state, for `FindATimeCheckpointStore`. Opaque
/// outside the package; the store only keeps and returns it.
public struct FindATimeCheckpoint: Hashable, Sendable, Codable {
    enum State: Hashable, Sendable, Codable {
        case initiating(Initiating)
        case invited(Invited)
    }

    let state: State

    public var interaction: InteractionID {
        switch state {
        case .initiating(let value): value.interaction.id
        case .invited(let value): value.interaction.id
        }
    }
}

/// Keeps checkpoints across app launches. The app passes a persistent one;
/// `InMemoryFindATimeCheckpoints` is the default and the test double.
public protocol FindATimeCheckpointStore: Sendable {
    func all() async throws -> [FindATimeCheckpoint]
    func save(_ checkpoint: FindATimeCheckpoint) async throws
    func remove(_ interaction: InteractionID) async throws
}

public actor InMemoryFindATimeCheckpoints: FindATimeCheckpointStore {
    private var items: [InteractionID: FindATimeCheckpoint] = [:]

    public init() {}

    public func all() async throws -> [FindATimeCheckpoint] { Array(items.values) }
    public func save(_ checkpoint: FindATimeCheckpoint) async throws { items[checkpoint.interaction] = checkpoint }
    public func remove(_ interaction: InteractionID) async throws { items[interaction] = nil }
}

/// One JSON file per live interaction in a directory the app chooses (for
/// example Application Support). Files are written atomically and, on iOS,
/// with complete file protection: they hold candidate times and friends'
/// IDs, and are removed when the interaction ends.
public actor FileFindATimeCheckpoints: FindATimeCheckpointStore {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func all() async throws -> [FindATimeCheckpoint] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            // A damaged file is skipped: its interaction is reported failed.
            .compactMap { try? decoder.decode(FindATimeCheckpoint.self, from: Data(contentsOf: $0)) }
    }

    public func save(_ checkpoint: FindATimeCheckpoint) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try encoder.encode(checkpoint).write(to: url(for: checkpoint.interaction), options: options)
    }

    public func remove(_ interaction: InteractionID) async throws {
        let url = url(for: interaction)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func url(for interaction: InteractionID) -> URL {
        directory.appendingPathComponent("\(interaction.rawValue.uuidString).json")
    }
}
