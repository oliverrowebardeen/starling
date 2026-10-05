import Foundation
import PickAPlace
import StarlingChangePlan
import StarlingCore

/// Which change holds each plan on this phone (ADR 0023), kept on the main
/// actor so cards and "Suggest a change" can say so as they draw. The app
/// creates the one `PlanChangeHolds`, passes it to every skill that changes
/// a plan, and follows its updates here.
@MainActor
@Observable
public final class PlanChangesInProgress {
    /// What the owner sees while another change holds the plan.
    nonisolated public static let note = "Another change to this plan is in progress."
    /// The skills whose changes hold a plan.
    nonisolated public static let skills: Set<SkillID> = [.pickAPlace, .changePlan]

    /// Whether a skill refused because another change holds the plan.
    nonisolated public static func isRefusal(_ error: any Error) -> Bool {
        if case .planBusy? = error as? ChangePlanError { return true }
        if case .planChangeInProgress? = error as? PickAPlaceError { return true }
        return false
    }

    /// The holds the app passes to Pick a place and Change the plan.
    public let holds: PlanChangeHolds
    /// The change holding each plan, by `Plan.origin`.
    public private(set) var holders: [ConversationID: ConversationID] = [:]
    @ObservationIgnored private var watching: Task<Void, Never>?

    public init(_ holds: PlanChangeHolds) { self.holds = holds }

    /// The change holding the plan named `origin`, if any.
    public func change(holding origin: ConversationID) -> ConversationID? { holders[origin] }

    /// Whether a change other than `change` holds the plan named `origin`.
    public func isHeld(_ origin: ConversationID, byOtherThan change: ConversationID? = nil) -> Bool {
        guard let holder = holders[origin] else { return false }
        return holder != change
    }

    /// Follows the holds from now on, so each hold or release reaches the
    /// cards at once. Runs once; the holds as they stand arrive first.
    func watch() async {
        guard watching == nil else { return }
        let updates = await holds.updates()
        guard watching == nil else { return }
        watching = Task { [weak self] in
            for await holders in updates {
                guard let self else { return }
                if holders != self.holders { self.holders = holders }
            }
        }
    }
}
