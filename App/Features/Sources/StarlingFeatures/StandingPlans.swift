import Foundation
import StarlingChangePlan
import StarlingCore

/// The plans on this phone, found by the conversation that names them to
/// everyone in them (`Plan.origin`, P15-E requests 10 and 14), for skill
/// services built in `makeSkills`. A friend added to a plan later holds it
/// in another interaction than the one it was agreed in, so the origin is
/// the only name every phone shares. Read live from the coordinator.
@MainActor
public final class StandingPlans {
    private weak var lifecycle: LifecycleCoordinator?

    public init() {}

    func attach(_ lifecycle: LifecycleCoordinator) { self.lifecycle = lifecycle }

    /// The standing plan named by `origin`, with the interaction that holds
    /// it, for Change the plan.
    public func standing(origin: ConversationID) -> PlanRef? {
        holder(origin: origin, states: [.planned]).flatMap { item in item.plan.map { PlanRef(interaction: item.id, plan: $0) } }
    }

    /// The plan named by `origin`, standing or just ended, for Swap photos
    /// (which runs after the plan ends).
    public func plan(origin: ConversationID) -> Plan? {
        holder(origin: origin, states: [.planned, .done])?.plan
    }

    private func holder(origin: ConversationID, states: Set<InteractionState>) -> Interaction? {
        (lifecycle?.interactions ?? []).planHolder(origin: origin, states: states)
    }
}

extension Array where Element == Interaction {
    /// The interaction holding the plan named `origin` among those in
    /// `states`: the one whose skill agreed it, or, on a friend's phone who
    /// was added later, their Change the plan interaction.
    func planHolder(origin: ConversationID, states: Set<InteractionState> = [.planned]) -> Interaction? {
        let holders = filter { states.contains($0.state) && $0.plan?.origin == origin }
        return holders.first { $0.skill.id != .changePlan } ?? holders.first
    }
}
