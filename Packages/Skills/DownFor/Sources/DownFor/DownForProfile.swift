import Foundation
import StarlingCore
import StarlingNegotiation

/// What code, not the model, decides about one Down for... request: which
/// plans are allowed, how to answer a friend's query, and what the PSI set
/// holds. Every plan that leaves the phone passes `permits` first
/// (ARCHITECTURE rule 6).
///
/// A Down for... plan has exactly one time slot, one or more activity
/// keywords, an optional budget cap, and, for a group of three or more, the
/// roster under `people` with the plan's starter first. A pair's roster is
/// the two ends of the conversation, so it is not sent: a People topic set
/// to Ask me then raises no sheet for "you and Maya". Nothing else.
struct DownForProfile: Sendable {
    static let namespace = "down_for/v1"
    static let planIssues: Set<IssueKey> = [.time, .activity, .budget, .people]

    let constraints: ConstraintSet
    let timeZone: TimeZone
    let expiresAt: Date
    /// Soft preferences, in the owner's order, never including an avoided one.
    let liked: [Keyword]
    let avoided: Set<Keyword>

    /// - Parameter inputs: Artifacts from a chained skill. An agreed
    ///   `TimeSlot` narrows the request to that slot.
    init(rules: OwnerRules, inputs: [Artifact], expiresAt: Date, timeZone: TimeZone) {
        var constraints = rules.constraints.constraints
        for case .timeSlot(let slot) in inputs {
            if let limit = try? Constraint(.within([slot])) { constraints[.time, default: []].append(limit) }
        }
        self.constraints = (try? ConstraintSet(constraints)) ?? rules.constraints
        self.timeZone = timeZone
        self.expiresAt = expiresAt

        var liked: [Keyword] = []
        var avoided = Set<Keyword>()
        for constraint in self.constraints[.activity] {
            if case .prefers(let like, let avoid) = constraint.rule {
                liked += like
                avoided.formUnion(avoid)
            }
        }
        var seen = Set<Keyword>()
        self.liked = liked.filter { !avoided.contains($0) && seen.insert($0).inserted }
        self.avoided = avoided
    }

    /// The free half-hours from `now` until the request expires, as a PSI set.
    func tokens(now: Date) -> SlotTokenSet {
        SlotTokenSet(namespace: Self.namespace, constraints: constraints, now: now, expiresAt: expiresAt, timeZone: timeZone)
    }

    // MARK: - The gate

    /// True when `plan` has the Down for... shape, names `me` and `member`
    /// (the friend at the starter's other end of this exchange) in its
    /// roster with `hub` first, has not started, ends before the request expires, and
    /// breaks none of the owner's hard limits.
    func permits(_ plan: Terms, me: PeerID, hub: PeerID, member: PeerID, now: Date) -> Bool {
        guard isWellFormed(plan), let roster = Self.roster(of: plan, hub: hub, member: member),
              roster.first == hub, roster.contains(me), roster.contains(member),
              let slot = Self.slot(of: plan), slot.end <= expiresAt, Self.hasNotStarted(slot, now: now)
        else { return false }
        return constraints.violations(of: plan, timeZone: timeZone).isEmpty
    }

    func isWellFormed(_ plan: Terms) -> Bool {
        guard Set(plan.values.keys).isSubset(of: Self.planIssues), Self.slot(of: plan) != nil,
              case .keywords(let activities)? = plan[.activity], !activities.isEmpty
        else { return false }
        switch plan[.people] {
        // One form per plan: a sent roster is a group's.
        case nil: break
        case .peers(let peers)? where peers.count >= 3: break
        default: return false
        }
        switch plan[.budget] {
        // A different currency from the cap is a violation (currencyMismatch).
        case nil, .amount?: return true
        default: return false
        }
    }

    /// True when a query or answer value breaks none of the owner's limits.
    func permits(_ issue: IssueKey, _ value: IssueValue) -> Bool {
        guard let terms = try? Terms([issue: value]) else { return false }
        return constraints.violations(of: terms, timeZone: timeZone).isEmpty
    }

    // MARK: - Answering a starter's query

    /// The candidates this owner accepts, in the starter's order. `matches`
    /// is the model's opinion; code keeps only pairs of a liked keyword and a
    /// real candidate, adds exact matches the model missed, and drops
    /// anything avoided (ADR 0121).
    func acceptableActivities(candidates: [Keyword], matches: [KeywordMatch]) -> [Keyword] {
        let usable = candidates.filter { !avoided.contains($0) }
        guard !liked.isEmpty else { return usable }
        let likedSet = Set(liked)
        var accepted = Set(usable.filter(likedSet.contains))
        for match in matches where likedSet.contains(match.wanted) {
            accepted.insert(match.offered)
        }
        return usable.filter(accepted.contains)
    }

    // MARK: - Reading plans

    static func slot(of plan: Terms) -> TimeSlot? {
        guard case .slots(let slots)? = plan[.time], slots.count == 1 else { return nil }
        return slots[0]
    }

    /// Everyone in the plan: the roster it carries, or for a pair, the
    /// starter and `member`, the friend at the other end.
    static func roster(of plan: Terms, hub: PeerID, member: PeerID) -> [PeerID]? {
        switch plan[.people] {
        case .peers(let peers)?: return peers
        case nil: return hub == member ? nil : [hub, member]
        default: return nil
        }
    }

    static func activity(of plan: Terms) -> Keyword? {
        guard case .keywords(let keywords)? = plan[.activity] else { return nil }
        return keywords.first
    }

    /// True when the slot is still ahead: its start is no earlier than the
    /// current minute.
    static func hasNotStarted(_ slot: TimeSlot, now: Date) -> Bool {
        slot.startMinute >= Int64((now.timeIntervalSince1970 / 60).rounded(.down))
    }

    /// The plan every member builds from the agreed terms: the same people,
    /// activity, and time on every phone (ADR 0012).
    static func plan(from terms: Terms, origin: ConversationID, hub: PeerID, member: PeerID) -> Plan? {
        guard let roster = roster(of: terms, hub: hub, member: member), let attendees = try? Attendees(roster) else { return nil }
        return try? Plan(origin: origin, attendees: attendees, activity: activity(of: terms), time: slot(of: terms))
    }
}
