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

/// What the Down screen's status mark shows (lane BR's `MarkState`, mapped
/// in the app). There is deliberately no "negotiating" case: every step that
/// could drive it happens only when a friend's intent overlaps, so showing it
/// would reveal one-sided interest (docs/requests/BR.md, ARCHITECTURE s7).
public enum DownStatus: Hashable, Sendable {
    /// No intent out.
    case idle
    /// The intent is out and Starling is checking with friends.
    case searching
    /// A mutual match in the current intent.
    case match
    /// The intent ended without a match; shown briefly, then `idle`.
    case noMatch
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
    /// The saved rules' sharing, loaded when a review opens. The review shows
    /// it as a floor the intent can tighten but not loosen (ADR 0141).
    public private(set) var standingSharing: [DisclosureRule] = []
    public private(set) var status = DownStatus.idle

    private let service: any DownService
    private let interpreter: RulesInterpreter
    private let rules: any RulesStore
    private let peers: any PairedPeerStore
    private let notifier: any MatchNotifier
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date
    /// Called whenever the intent starts, is withdrawn, or ends, before the
    /// service hears about it. The app clears remembered consent here so an
    /// approval never carries over to another intent (ADR 0142).
    private let intentChanged: @MainActor () -> Void
    private let noMatchHold: Duration
    public let formatter: ValueFormatter
    private var listener: Task<Void, Never>?
    private var settle: Task<Void, Never>?

    public init(
        service: any DownService,
        interpreter: RulesInterpreter,
        rules: any RulesStore,
        peers: any PairedPeerStore,
        notifier: any MatchNotifier,
        formatter: ValueFormatter = ValueFormatter(),
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        intentChanged: @escaping @MainActor () -> Void = {},
        noMatchHold: Duration = .seconds(3)
    ) {
        self.intentChanged = intentChanged
        self.noMatchHold = noMatchHold
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
        await loadStanding()
        switch await interpreter.interpret(text) {
        case .draft(let draft):
            self.draft = draft
            interpretedFrom = text
            phase = .reviewing
        case .handEdit(let notice):
            self.notice = notice
            openEmptyReview()
        case .failed(let message):
            notice = message
            phase = .composing
        }
    }

    public func editByHand() async {
        guard phase == .composing else { return }
        await loadStanding()
        openEmptyReview()
    }

    /// Sets one issue's sharing for this intent, never looser than the saved rules.
    public func setSharing(_ action: DisclosureRule.Action, for issue: IssueKey) {
        draft.setSharing(action, for: issue, standing: standingSharing)
    }

    public var sharingRows: [RulesDraft.SharingRow] {
        draft.sharingRows(standing: standingSharing)
    }

    private func setStatus(_ new: DownStatus) {
        settle?.cancel()
        settle = nil
        status = new
    }

    private func openEmptyReview() {
        draft = .empty
        interpretedFrom = nil
        phase = .reviewing
    }

    static let standingChangedNotice = "Your saved sharing rules changed. Check \"What may leave your phone\" again, then go down."

    /// Reloads the saved rules while a review is open, for example when the
    /// Down screen reappears after the owner edited the Rules tab. If their
    /// sharing changed, the rows update and the owner is told to look again.
    public func refreshStandingRules() async {
        guard phase == .reviewing else { return }
        let current = (try? await rules.load())?.rules.disclosure ?? []
        guard Set(current) != Set(standingSharing) else { return }
        standingSharing = current
        notice = Self.standingChangedNotice
    }

    private func loadStanding() async {
        standingSharing = (try? await rules.load())?.rules.disclosure ?? []
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
            // The saved rules may have changed in the Rules tab since this
            // review opened. Publish only what the owner has seen.
            if Set(standing.disclosure) != Set(standingSharing) {
                standingSharing = standing.disclosure
                notice = Self.standingChangedNotice
                phase = .reviewing
                return
            }
            guard let merged = try? RulesMerge.intent(intentRules, standing: standing) else {
                notice = "Together with your saved rules, this has too many rules on one topic. Remove some."
                phase = .reviewing
                return
            }
            let expiresAt = duration.expiry(from: now(), timeZone: timeZone)
            intentChanged()
            // The service may report checking, a match, or an end before
            // setIntent returns, so the new intent's state exists first and
            // events update it as they arrive (phase stays .starting).
            active = Active(level: level, expiresAt: expiresAt)
            matches = []
            setStatus(.searching)
            try await service.setIntent(DownIntent(rules: merged, level: level, expiresAt: Timestamp(expiresAt)))
            // An .ended event while in flight already moved on; keep that.
            guard phase == .starting else { return }
            text = ""
            interpretedFrom = nil
            phase = .active
        } catch {
            guard phase == .starting else { return }
            active = nil
            setStatus(.idle)
            notice = SendFailureMessage.text(for: error) ?? "Starling couldn't start checking. Try again."
            phase = .reviewing
        }
    }

    /// Friends learn nothing beyond "no match".
    public func withdraw() async {
        guard phase == .active else { return }
        intentChanged()
        await service.clearIntent()
        // The owner's own choice, not a "no match": straight back to idle.
        setStatus(.idle)
        active = nil
        draft = .empty
        phase = .composing
    }

    func handle(_ event: DownEvent) async {
        switch event {
        case .checking(let friends):
            active?.checkingFriends = friends
            if active != nil && status != .match { setStatus(.searching) }
        case .matched(let match):
            let name = (try? await peers.peer(for: match.peer))?.nickname ?? "A paired friend"
            let row = MatchRow(id: match.peer, friendName: name, lines: formatter.terms(match.terms), bothDown: match.bothDown, matchedAt: now())
            matches.removeAll { $0.id == row.id }
            matches.insert(row, at: 0)
            if active != nil { setStatus(.match) }
            await notifier.post(MatchNotice(match: match, friendName: name, formatter: formatter))
        case .ended(let reason):
            guard phase == .active || phase == .starting else { return }
            intentChanged()
            // After a match the intent simply ends; without one, the mark
            // shows "no match" briefly. Either way nothing names a friend.
            if status == .match {
                setStatus(.idle)
            } else {
                setStatus(.noMatch)
                let hold = noMatchHold
                settle = Task { [weak self] in
                    try? await Task.sleep(for: hold)
                    guard !Task.isCancelled else { return }
                    self?.setStatus(.idle)
                }
            }
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
