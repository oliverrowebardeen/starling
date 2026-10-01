import Foundation
import StarlingCore

/// What Pick a place must remember across launches, on this device only
/// (ADR 0230). Every read and write can fail; the service then refuses to
/// go on rather than guess, so a lost record never lets a friend learn
/// more or a request outlive its deadlines.
public protocol PickAPlaceLedger: Sendable {
    /// When each friend's requests were admitted, since `date`, so the
    /// hourly limit per friend survives a relaunch.
    func admissions(since date: Date) async throws -> [PeerID: [Date]]
    func recordAdmission(_ peer: PeerID, at date: Date) async throws
    /// Yeses this phone took back that the organizer has not yet
    /// acknowledged; retried until it does, across relaunches.
    func pendingWithdrawals() async throws -> [PendingWithdrawal]
    func recordWithdrawal(_ withdrawal: PendingWithdrawal) async throws
    func clearWithdrawal(_ conversation: ConversationID) async throws
    /// Every candidate this phone has said yes or no about in a
    /// conversation, across relaunches, so a friend learns about at most
    /// `ProtocolLimits.maxCandidatesAnsweredPerIssue` of them (ADR 0019,
    /// decision 6). Recorded before an answer leaves.
    func answeredCandidates(in conversation: ConversationID) async throws -> Set<PlaceChoice>
    func recordAnswered(_ candidates: Set<PlaceChoice>, in conversation: ConversationID, at date: Date) async throws
}

/// Candidates answered in one conversation.
public struct AnsweredCandidates: Codable, Hashable, Sendable {
    public var candidates: Set<PlaceChoice>
    public var since: Date
}

/// A yes this phone took back, waiting for the organizer to acknowledge it.
public struct PendingWithdrawal: Codable, Hashable, Sendable {
    public let conversation: ConversationID
    public let organizer: PeerID
    /// The proposal the yes answered, for the rejection to name.
    public let proposal: MessageID?
    public let chainedFrom: ConversationID?
    public let since: Date

    public init(conversation: ConversationID, organizer: PeerID, proposal: MessageID?, chainedFrom: ConversationID?, since: Date) {
        self.conversation = conversation
        self.organizer = organizer
        self.proposal = proposal
        self.chainedFrom = chainedFrom
        self.since = since
    }
}

/// The ledger could not be read or written.
public struct LedgerUnavailable: Error, Hashable, Sendable {
    public init() {}
}

/// Everything the ledger keeps, as one value both implementations share.
public struct PickAPlaceLedgerState: Codable, Hashable, Sendable {
    public var admissions: [PeerID: [Date]] = [:]
    public var withdrawals: [ConversationID: PendingWithdrawal] = [:]
    public var answered: [ConversationID: AnsweredCandidates] = [:]

    public init() {}

    /// How long answered candidates are kept: past any request's life, and
    /// past the day of ended requests a restart restores.
    public static let answeredLifetime: TimeInterval = 48 * 3_600

    /// How long a withdrawal is retried before the organizer is assumed gone.
    public static let withdrawalLifetime: TimeInterval = 24 * 3_600

    private enum CodingKeys: String, CodingKey { case admissions, withdrawals, answered }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        admissions = try c.decodeIfPresent([PeerID: [Date]].self, forKey: .admissions) ?? [:]
        withdrawals = try c.decodeIfPresent([ConversationID: PendingWithdrawal].self, forKey: .withdrawals) ?? [:]
        answered = try c.decodeIfPresent([ConversationID: AnsweredCandidates].self, forKey: .answered) ?? [:]
    }

    mutating func addAnswered(_ candidates: Set<PlaceChoice>, in conversation: ConversationID, at date: Date) {
        if var entry = answered[conversation] {
            entry.candidates.formUnion(candidates)
            answered[conversation] = entry
        } else {
            answered[conversation] = AnsweredCandidates(candidates: candidates, since: date)
        }
    }

    /// Drops what is too old to matter.
    mutating func prune(now: Date) {
        let hourAgo = now.addingTimeInterval(-3_600)
        admissions = admissions.mapValues { $0.filter { $0 > hourAgo } }.filter { !$0.value.isEmpty }
        withdrawals = withdrawals.filter { now.timeIntervalSince($0.value.since) < Self.withdrawalLifetime }
        answered = answered.filter { now.timeIntervalSince($0.value.since) < Self.answeredLifetime }
    }
}

/// For tests and previews. One instance survives a restarted service, and
/// `failing` makes every call throw, as an unreadable store would.
public actor InMemoryPickAPlaceLedger: PickAPlaceLedger {
    public private(set) var state = PickAPlaceLedgerState()
    public var failing = false
    /// Fails only the answered-candidate records.
    public var failingAnswered = false

    public init() {}

    public func setFailing(_ failing: Bool) { self.failing = failing }
    public func setFailingAnswered(_ failing: Bool) { failingAnswered = failing }

    public func answeredCandidates(in conversation: ConversationID) async throws -> Set<PlaceChoice> {
        guard !failing, !failingAnswered else { throw LedgerUnavailable() }
        return state.answered[conversation]?.candidates ?? []
    }

    public func recordAnswered(_ candidates: Set<PlaceChoice>, in conversation: ConversationID, at date: Date) async throws {
        guard !failing, !failingAnswered else { throw LedgerUnavailable() }
        state.addAnswered(candidates, in: conversation, at: date)
    }

    public func admissions(since date: Date) async throws -> [PeerID: [Date]] {
        guard !failing else { throw LedgerUnavailable() }
        return state.admissions.mapValues { $0.filter { $0 > date } }.filter { !$0.value.isEmpty }
    }

    public func recordAdmission(_ peer: PeerID, at date: Date) async throws {
        guard !failing else { throw LedgerUnavailable() }
        state.admissions[peer, default: []].append(date)
    }

    public func pendingWithdrawals() async throws -> [PendingWithdrawal] {
        guard !failing else { throw LedgerUnavailable() }
        return Array(state.withdrawals.values)
    }

    public func recordWithdrawal(_ withdrawal: PendingWithdrawal) async throws {
        guard !failing else { throw LedgerUnavailable() }
        state.withdrawals[withdrawal.conversation] = withdrawal
    }

    public func clearWithdrawal(_ conversation: ConversationID) async throws {
        guard !failing else { throw LedgerUnavailable() }
        state.withdrawals[conversation] = nil
    }
}

/// The app's ledger, as JSON in `UserDefaults`. Old entries are pruned on
/// every write.
public actor UserDefaultsPickAPlaceLedger: PickAPlaceLedger {
    private let defaults: UserDefaults
    private let key: String

    /// - Parameter suiteName: nil for the standard defaults.
    public init(suiteName: String? = nil, key: String = "starling.pick_a_place.ledger") {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.key = key
    }

    public func admissions(since date: Date) async throws -> [PeerID: [Date]] {
        try read().admissions.mapValues { $0.filter { $0 > date } }.filter { !$0.value.isEmpty }
    }

    public func recordAdmission(_ peer: PeerID, at date: Date) async throws {
        try update(now: date) { $0.admissions[peer, default: []].append(date) }
    }

    public func pendingWithdrawals() async throws -> [PendingWithdrawal] {
        Array(try read().withdrawals.values)
    }

    public func answeredCandidates(in conversation: ConversationID) async throws -> Set<PlaceChoice> {
        try read().answered[conversation]?.candidates ?? []
    }

    public func recordAnswered(_ candidates: Set<PlaceChoice>, in conversation: ConversationID, at date: Date) async throws {
        try update(now: date) { $0.addAnswered(candidates, in: conversation, at: date) }
    }

    public func recordWithdrawal(_ withdrawal: PendingWithdrawal) async throws {
        try update(now: Date()) { $0.withdrawals[withdrawal.conversation] = withdrawal }
    }

    public func clearWithdrawal(_ conversation: ConversationID) async throws {
        try update(now: Date()) { $0.withdrawals[conversation] = nil }
    }

    func read() throws -> PickAPlaceLedgerState {
        guard let data = defaults.data(forKey: key) else { return PickAPlaceLedgerState() }
        do { return try JSONDecoder().decode(PickAPlaceLedgerState.self, from: data) } catch { throw LedgerUnavailable() }
    }

    func update(now: Date, _ change: (inout PickAPlaceLedgerState) -> Void) throws {
        var state = try read()
        change(&state)
        state.prune(now: now)
        do { defaults.set(try JSONEncoder().encode(state), forKey: key) } catch { throw LedgerUnavailable() }
    }
}
