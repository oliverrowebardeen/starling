import Foundation
import StarlingChaining
import StarlingChangePlan
import StarlingCore

/// "Suggest a change" and "Leave this plan" on a plan's detail (ADR 0022,
/// P15-E request 11). A suggestion goes to everyone else in the plan and
/// applies only if they all say yes; leaving needs nobody's agreement.
extension AppModel {
    /// The suggestion row lane E offers for this plan, or nil.
    public func changeOffer(for root: Interaction) -> ChainSuggestion? {
        guard let me = localPeer, lifecycle.skillsInBuild.contains(.changePlan) else { return nil }
        return ChainPlanner(registry: services.registry, me: me)
            .changeOffer(for: root.id, in: lifecycle.interactions, settings: settings.skillSettings, cards: cards.cards, now: Date())
    }

    /// Why "Suggest a change" is off for a standing plan, in plain words, or
    /// nil when it is on. Never off without saying why.
    public func changeUnavailableReason(for root: Interaction) -> String? {
        guard root.state == .planned, root.plan != nil else { return "Only a plan that's still on can change." }
        if changeOffer(for: root) != nil { return nil }
        guard lifecycle.skillsInBuild.contains(.changePlan) else { return "Changing a plan isn't in this build yet." }
        guard settings.isOn(.changePlan) else { return "Change the plan is off in You." }
        if ChainPlanner.openChange(for: root, in: lifecycle.interactions) != nil { return "A suggestion for this plan is still open." }
        if (root.plan?.revision ?? 0) >= ChainPlanner.maxChangeableRevision { return "This plan has changed as many times as it can." }
        if let end = root.plan?.endsAt, Date() >= end { return "This plan has already happened." }
        return "Not everyone's Starling can change plans yet."
    }

    /// What a suggestion also uses, said before the owner taps (their tap
    /// is the approval, as for Keep it going).
    public func changeAddsNote(_ row: ChainSuggestion) -> String? {
        guard row.needsConsent else { return nil }
        var parts: [String] = []
        if !row.adds.topics.isEmpty { parts.append("uses your \(PermissionExplanation.names(row.adds.topics.sorted().map { $0.label.lowercased() }))") }
        if !row.adds.permissions.isEmpty { parts.append("may ask for \(PermissionExplanation.names(row.adds.permissions.sorted { $0.rawValue < $1.rawValue }.map(\.label)))") }
        return parts.isEmpty ? nil : "This suggestion also " + parts.joined(separator: " and ") + "."
    }

    /// Friends who could be added: the owner's, not in the plan yet, whose
    /// Starling can change plans.
    public func friendsToAdd(to root: Interaction) -> [PairedPeer] {
        let inPlan = Set(root.plan?.attendees.peers ?? [])
        return (friends?.friends ?? []).filter { friend in
            !inPlan.contains(friend.id) && cards.support(of: friend.id, for: ChangePlan.descriptor.ref)?.isSupported == true
        }
    }

    /// Suggests `change` for the plan `root` holds. Returns why it could not
    /// start, in plain words, or nil once it is on its way.
    public func suggestChange(_ change: PlanChange, on root: Interaction) async -> String? {
        if let reason = changeUnavailableReason(for: root) { return reason }
        guard let me = localPeer, let plan = root.plan, let row = changeOffer(for: root) else { return "This plan can't change right now." }
        let now = Date()
        let tap = Timestamp(now)
        do {
            let encoded = try change.encoded(for: plan)
            let start = try ChainPlanner(registry: services.registry, me: me).beginChange(
                row, in: lifecycle.interactions, settings: settings.skillSettings, cards: cards.cards, now: now,
                tap: OwnerTap(at: tap), consent: row.needsConsent ? row.consent(approvedAt: tap) : nil,
                rules: encoded.rules, extraInputs: encoded.inputs, expiresAt: ChangePlan.defaultExpiry(for: plan, now: now)
            )
            try await lifecycle.start(start.request, chain: start.interaction.chain, settings: settings.skillSettings)
            return nil
        } catch PlanChange.Invalid.nothingToChange {
            return "That's how the plan is already."
        } catch ChainError.cannotAdd {
            return "That friend can't be added to this plan."
        } catch let refusal as StartRefusal {
            return ComposerModel.refusalNote(refusal, ChangePlan.descriptor)
        } catch {
            return "This plan can't change right now. Open it again."
        }
    }

    /// Leaves the plan `root` holds. The others see that you left; nobody
    /// else is asked. Returns why it could not, or nil.
    public func leavePlan(_ root: Interaction) async -> String? {
        guard let me = localPeer, let plan = root.plan, root.state == .planned else { return "Only a plan that's still on can be left." }
        let now = Date()
        do {
            let encoded = try PlanChange.leave.encoded(for: plan)
            let start = try ChainPlanner(registry: services.registry, me: me).beginLeave(
                from: root.id, in: lifecycle.interactions, settings: settings.skillSettings, tap: OwnerTap(at: Timestamp(now)),
                rules: encoded.rules, expiresAt: Timestamp(now.addingTimeInterval(3600))
            )
            try await lifecycle.start(start.request, chain: start.interaction.chain, settings: settings.skillSettings)
            return nil
        } catch let refusal as StartRefusal {
            return ComposerModel.refusalNote(refusal, ChangePlan.descriptor)
        } catch {
            return "Starling couldn't leave this plan. Try again."
        }
    }

    /// A yes to a change of place is final once sent (Orchestrator, ADR
    /// 0233): a Pick a place on a plan that has a place, after the owner
    /// said yes. Its card and detail then offer no "Not this one" and no
    /// Withdraw, and point to "Suggest a change" or "Leave this plan".
    public func placeYesIsFinal(_ item: Interaction) -> Bool {
        // The owner's yes moves a card to confirmed; it stays said after.
        guard item.skill.id == .pickAPlace, !item.state.isFinal,
              item.history.contains(where: { [.confirmed, .planned, .done].contains($0.state) }) else { return false }
        let all = lifecycle.interactions
        let plan: Plan? = if let parent = item.chain?.parent {
            all.first { $0.id == parent }?.plan
        } else if let hint = item.friendChainHint {
            all.first { $0.skill.id != .pickAPlace && $0.planConversation == hint }?.plan
        } else {
            nil
        }
        return plan?.place != nil
    }

    public static let placeYesIsFinalNote = "Your yes to this place is final. To change the plan, use Suggest a change or Leave this plan."

}
