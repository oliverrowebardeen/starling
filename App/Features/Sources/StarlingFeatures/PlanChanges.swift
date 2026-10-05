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
        guard root.state == .planned, let plan = root.plan else { return "Only a plan that's still on can change." }
        // One change per plan at a time (ADR 0023), a place as well.
        if services.changesInProgress?.isHeld(plan.origin) == true || ChainPlanner.openChange(for: root, in: lifecycle.interactions) != nil {
            return PlanChangesInProgress.note
        }
        if changeOffer(for: root) != nil { return nil }
        guard lifecycle.skillsInBuild.contains(.changePlan) else { return "Changing a plan isn't in this build yet." }
        guard settings.isOn(.changePlan) else { return "Change the plan is off in You." }
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
        return planChanged(by: item)?.place != nil
    }

    nonisolated public static let placeYesIsFinalNote = "Your yes to this place is final. To change the plan, use Suggest a change or Leave this plan."

    /// The plan a Pick a place or Change the plan interaction changes: the
    /// one its link names, or, on a friend's phone, the one its card is
    /// grouped under. Nil for anything else.
    public func planChanged(by item: Interaction) -> Plan? {
        guard PlanChangesInProgress.skills.contains(item.skill.id) else { return nil }
        let all = lifecycle.interactions
        if let parent = item.chain?.parent { return all.first { $0.id == parent }?.plan }
        guard let hint = item.friendChainHint else { return nil }
        return all.first { $0.skill.id != item.skill.id && $0.planConversation == hint && $0.plan != nil }?.plan
    }

    /// The owner's answer to a card. A yes to a change is not sent while
    /// another change holds its plan (ADR 0023): the skill would turn it
    /// away after the card had moved on, so the holds are asked first and
    /// the card stays as it was. Returns whether the answer was taken.
    public func answer(_ id: InteractionID, with answer: OwnerAnswer) async -> Bool {
        if case .accept = answer, let item = lifecycle.interaction(id), let plan = planChanged(by: item),
           let holds = services.changesInProgress?.holds,
           let holder = await holds.holder(of: plan.origin), holder != item.conversation {
            return false
        }
        return await lifecycle.answer(id, with: answer)
    }

    /// Why a card asking the owner offers less than its usual answers, or
    /// nil when it offers both.
    public func answerLimit(_ item: Interaction) -> AnswerLimit? {
        if placeYesIsFinal(item) { return .yesIsFinal }
        // Another change holds this card's plan (ADR 0023): a yes would be
        // turned away, so it is not offered. A no still goes.
        if item.state == .proposed, item.role != .initiator, let plan = planChanged(by: item),
           services.changesInProgress?.isHeld(plan.origin, byOtherThan: item.conversation) == true {
            return .anotherChangeInProgress
        }
        return nil
    }

}

/// What a card asking the owner leaves out, and the line it shows instead.
public enum AnswerLimit: Equatable, Sendable {
    /// A yes to a change of place was sent and is final (ADR 0233): no
    /// answers at all.
    case yesIsFinal
    /// Another change to the plan is open on this phone (ADR 0023): no yes.
    case anotherChangeInProgress

    public var note: String {
        switch self {
        case .yesIsFinal: AppModel.placeYesIsFinalNote
        case .anotherChangeInProgress: PlanChangesInProgress.note
        }
    }

    /// Whether the card still offers its no.
    public var offersNo: Bool { self == .anotherChangeInProgress }
}
