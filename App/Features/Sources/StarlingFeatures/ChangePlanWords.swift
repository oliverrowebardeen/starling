import Foundation
import StarlingCore

/// The words for Change the plan (ADR 0022, ADR 0243): suggestion cards,
/// the suggester's waiting card, and the plan's timeline. Names are the
/// owner's own nicknames, never text a peer sent. A change that did not go
/// through names nobody: the suggester reads "The plan stays as it was",
/// and everyone else's card just closes.
extension InteractionWords {
    public static let staysAsItWas = "The plan stays as it was"

    /// Whether `item` is a change to a plan this phone holds elsewhere (so
    /// it belongs on that plan's timeline, never as a plan of its own). A
    /// friend added to a plan holds it in their Change the plan interaction,
    /// which then is the plan.
    public static func isChange(_ item: Interaction, among all: [Interaction]) -> Bool {
        guard item.skill.id == .changePlan else { return false }
        guard let origin = item.plan?.origin else { return true }
        return all.contains { $0.id != item.id && $0.skill.id != .changePlan && $0.plan?.origin == origin }
    }

    /// The plan a change on this phone is about: the one its link names,
    /// or the one a friend's suggestion is grouped under.
    public static func basis(of item: Interaction, among all: [Interaction]) -> Plan? {
        guard item.skill.id == .changePlan else { return nil }
        if let parent = item.chain?.parent { return all.first { $0.id == parent }?.plan }
        if let hint = item.friendChainHint {
            return all.first { $0.skill.id != .changePlan && $0.planConversation == hint && $0.plan != nil }?.plan
        }
        return nil
    }

    /// "8:30 PM instead of 8 PM", "dinner instead of boba", "adding Jake":
    /// what `terms` change in `basis`.
    public func changeParts(_ terms: Terms, basis: Plan?) -> [String] {
        var parts: [String] = []
        if case .slots(let slots)? = terms.values[.time], let slot = slots.first {
            if let old = basis?.time {
                let sameDay = chips.dayWord(old.start) == chips.dayWord(slot.start)
                let new = sameDay ? chips.hour(slot.start) : chips.start(slot).lowercasedFirstLetter
                let was = sameDay ? chips.hour(old.start) : chips.start(old).lowercasedFirstLetter
                parts.append("\(new) instead of \(was)")
            } else {
                parts.append(chips.start(slot).lowercasedFirstLetter)
            }
        }
        if case .keywords(let words)? = terms.values[.activity], let activity = words.first {
            parts.append(basis?.activity.map { "\(activity.value) instead of \($0.value)" } ?? activity.value)
        }
        if case .peers(let roster)? = terms.values[.people], let added = roster.last, basis?.attendees.peers.contains(added) != true {
            parts.append("adding \(friendNames([added]).first ?? Self.unpaired)")
        }
        return parts
    }

    /// An agreed change: "Changed to dinner, tonight at 8:30 PM", "Added
    /// Jake".
    func appliedChange(_ terms: Terms) -> String? {
        var changed: [String] = []
        if case .keywords(let words)? = terms.values[.activity], let activity = words.first { changed.append(activity.value) }
        if case .slots(let slots)? = terms.values[.time], let slot = slots.first { changed.append(chips.start(slot).lowercasedFirstLetter) }
        var lines: [String] = []
        if !changed.isEmpty { lines.append("changed to " + changed.joined(separator: ", ")) }
        if case .peers(let roster)? = terms.values[.people], let added = roster.last {
            lines.append("added \(friendNames([added]).first ?? Self.unpaired)")
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: ", ").capitalizedFirstLetter
    }

    /// The card for a friend's suggestion: "Maya suggests 8:30 PM instead
    /// of 8 PM". For a friend being added, the plan they are asked to join:
    /// "Maya asks you to join boba with Jake, Friday at 8 PM".
    public func suggestionCard(_ item: Interaction, basis: Plan?) -> String? {
        guard item.skill.id == .changePlan, item.role == .invitee, let proposal = item.proposal,
              let suggester = item.participants.first else { return nil }
        let who = friendNames([suggester]).first ?? Self.unpaired
        guard let basis else {
            let plan = proposal.plan
            let others = friendNames((plan?.attendees.peers ?? []).filter { $0 != suggester })
            var text = "\(who) asks you to join \(plan?.activity?.value ?? "a plan")"
            if !others.isEmpty { text += " with \(PermissionExplanation.names(others))" }
            if let time = plan?.time { text += ", \(chips.start(time).lowercasedFirstLetter)" }
            return text
        }
        let parts = changeParts(proposal.terms, basis: basis)
        guard !parts.isEmpty else { return nil }
        return "\(who) suggests \(PermissionExplanation.names(parts))"
    }

    /// A change while it is open: what it changes as the title, and where
    /// it stands. "Dinner instead of boba", "Waiting for everyone to say yes".
    func changeSummary(_ item: Interaction, basis: Plan?) -> InteractionSummary? {
        guard let summary = summary(item) else { return nil }
        let parts = item.proposal.map { changeParts($0.terms, basis: basis) } ?? []
        let title = parts.isEmpty ? summary.title : PermissionExplanation.names(parts).capitalizedFirstLetter
        let status: String = switch (item.role, item.state) {
        case (.initiator, .confirmed), (.initiator, .negotiating): "Waiting for everyone to say yes"
        case (.invitee, .confirmed): "You said yes. Waiting on everyone."
        default: summary.status
        }
        return InteractionSummary(interaction: item, skill: summary.skill, tag: summary.tag, title: title, status: status, pose: summary.pose)
    }

    /// A change's line on its plan's timeline, or nil to leave it off (a
    /// friend's suggestion that closed: nobody is named, ADR 0022).
    public func changeTimeline(_ item: Interaction, basis: Plan?) -> String? {
        guard item.skill.id == .changePlan else { return nil }
        let terms = item.proposal?.terms
        switch item.state {
        case .ended(.withdrawn) where terms == nil:
            if item.role == .initiator { return "You left this plan" }
            return "\(friendNames(Array(item.participants.prefix(1))).first ?? Self.unpaired) left"
        case .ended(.nobodyUp) where item.role == .initiator:
            return Self.staysAsItWas
        case .ended(.withdrawn) where item.role == .initiator:
            return "You took back your suggestion"
        case .ended, .done:
            return nil
        case .planned:
            guard let terms else { return "The plan changed" }
            return appliedChange(terms) ?? "The plan changed"
        default:
            guard let terms else { return nil }
            let parts = changeParts(terms, basis: basis)
            return item.role == .initiator ? "You suggested \(PermissionExplanation.names(parts))" : nil
        }
    }
}
