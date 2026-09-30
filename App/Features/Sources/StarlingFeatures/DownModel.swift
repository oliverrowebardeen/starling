import Foundation
import Observation
import StarlingCore

/// How long a Down? intent lasts.
public enum DownDuration: String, Hashable, Sendable, CaseIterable, Identifiable {
    case oneHour, threeHours, tonight

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .oneHour: "1 hour"
        case .threeHours: "3 hours"
        case .tonight: "Until midnight"
        }
    }

    public func expiry(from now: Date, timeZone: TimeZone) -> Date {
        switch self {
        case .oneHour: return now.addingTimeInterval(3600)
        case .threeHours: return now.addingTimeInterval(3 * 3600)
        case .tonight:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(3 * 3600)
        }
    }
}

/// The Down? screen: say what you're up for, review it, choose down or maybe
/// and an expiry, then see mutual matches. Notifies only on `.matched`.
@MainActor
@Observable
public final class DownModel {
    public enum Phase: Hashable, Sendable {
        case composing, interpreting, reviewing, starting, active
    }

    public struct Active: Hashable, Sendable {
        public let level: DownLevel
        public let expiresAt: Date
        /// Set once the service reports how many friends it is checking.
        public fileprivate(set) var checkingFriends: Int?
    }

    public struct MatchRow: Identifiable, Hashable, Sendable {
        public let id: PeerID
        public let friendName: String
        public let lines: [DisplayLine]
        public let bothDown: Bool
        public let matchedAt: Date
    }

    public var text = ""
    public var draft = RulesDraft.empty
    public var level = DownLevel.down
    public var duration = DownDuration.threeHours
    public private(set) var phase = Phase.composing
    public private(set) var active: Active?
    public private(set) var matches: [MatchRow] = []
    public private(set) var notice: String?
    public private(set) var interpretedFrom: String?

    private let service: any DownService
    private let interpreter: RulesInterpreter
    private let rules: any RulesStore
    private let peers: any PairedPeerStore
    private let notifier: any MatchNotifier
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date
    public let formatter: ValueFormatter
    private var listener: Task<Void, Never>?

    public init(
        service: any DownService,
        interpreter: RulesInterpreter,
        rules: any RulesStore,
        peers: any PairedPeerStore,
        notifier: any MatchNotifier,
        formatter: ValueFormatter = ValueFormatter(),
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.interpreter = interpreter
        self.rules = rules
        self.peers = peers
        self.notifier = notifier
        self.formatter = formatter
        self.timeZone = timeZone
        self.now = now
    }

    public var flags: [UUID: String] {
        interpretedFrom.map { draft.reviewFlags(for: $0, formatter: formatter) } ?? [:]
    }

    /// Starts consuming the service's events. `DownService.events` has a
    /// single consumer, so the app calls this once, at launch, and keeps the
    /// model for its lifetime so matches notify from any screen.
    public func listen() {
        guard listener == nil else { return }
        let events = service.events
        listener = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    public func interpret() async {
        guard phase == .composing else { return }
        phase = .interpreting
        notice = nil
        switch await interpreter.interpret(text) {
        case .draft(let draft):
            self.draft = draft
            interpretedFrom = text
            phase = .reviewing
        case .handEdit(let notice):
            self.notice = notice
            editByHand()
        case .failed(let message):
            notice = message
            phase = .composing
        }
    }

    public func editByHand() {
        draft = .empty
        interpretedFrom = nil
        phase = .reviewing
    }

    public func discard() {
        guard phase == .reviewing else { return }
        draft = .empty
        interpretedFrom = nil
        phase = .composing
    }

    /// Publishes the reviewed intent, merged with the saved standing rules.
    public func goDown() async {
        guard phase == .reviewing else { return }
        let intentRules: OwnerRules
        do { intentRules = try draft.build() } catch {
            notice = "Fix the rows marked in red first."
            return
        }
        phase = .starting
        notice = nil
        do {
            let standing = try await rules.load()?.rules ?? .empty
            guard let merged = try? RulesMerge.intent(intentRules, standing: standing) else {
                notice = "Together with your saved rules, this has too many rules on one topic. Remove some."
                phase = .reviewing
                return
            }
            let expiresAt = duration.expiry(from: now(), timeZone: timeZone)
            try await service.setIntent(DownIntent(rules: merged, level: level, expiresAt: Timestamp(expiresAt)))
            active = Active(level: level, expiresAt: expiresAt)
            matches = []
            text = ""
            interpretedFrom = nil
            phase = .active
        } catch {
            notice = "Starling couldn't start checking. Try again."
            phase = .reviewing
        }
    }

    /// Friends learn nothing beyond "no match".
    public func withdraw() async {
        guard phase == .active else { return }
        await service.clearIntent()
        active = nil
        draft = .empty
        phase = .composing
    }

    func handle(_ event: DownEvent) async {
        switch event {
        case .checking(let friends):
            active?.checkingFriends = friends
        case .matched(let match):
            let name = (try? await peers.peer(for: match.peer))?.nickname ?? "A paired friend"
            let row = MatchRow(id: match.peer, friendName: name, lines: formatter.terms(match.terms), bothDown: match.bothDown, matchedAt: now())
            matches.removeAll { $0.id == row.id }
            matches.insert(row, at: 0)
            await notifier.post(MatchNotice(match: match, friendName: name, formatter: formatter))
        case .ended(let reason):
            guard phase == .active || phase == .starting else { return }
            active = nil
            draft = .empty
            phase = .composing
            switch reason {
            case .expired: notice = "Your Down? reached its end time."
            case .withdrawn: notice = nil
            case .failed: notice = "Starling stopped checking because something went wrong. Nobody was notified."
            }
        }
    }
}
