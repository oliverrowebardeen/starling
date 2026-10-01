import Foundation
import StarlingCore

// Time-triggered chains (ADR 0012 decision 5, ADR 0240). A skill with
// `ChainTrigger.afterPlanEnds` starts when `Plan.endsAt` passes, and only if
// the owner opted in at Confirm. The opt-in is a waiting interaction with a
// `ChainLink` (see `ChainPlanner.optIn`), saved in the app's store, so it
// survives a restart. When the plan ends, the schedule checks everything
// again and either starts the link or says why it will not run.

/// An after-plan-ends link whose plan has ended, ready to start.
public struct DueChain: Hashable, Sendable {
    public let link: Interaction
    public let parent: Interaction
    public let plan: Plan

    /// The request to hand the skill's service once the coordinator has
    /// applied `.started` to `link`. Carries the plan and `chainedFrom`.
    public func request(rules: OwnerRules, expiresAt: Timestamp) -> SkillRequest {
        let inputs = ChainPlanner.inputs(link.chain?.consumed ?? [], from: parent)
        return ChainPlanner.request(for: link, inputs: inputs, rules: rules, expiresAt: expiresAt)
    }
}

/// What to do with one waiting link.
public enum ScheduledChain: Hashable, Sendable {
    /// The plan ended and everything still holds: start it.
    case start(DueChain)
    /// It will not run. Apply `event` (withdrawn, unsupported, or blocked by
    /// privacy) so it ends in history with a reason instead of waiting
    /// forever.
    case cancel(Interaction, InteractionEvent)

    /// The waiting link this decision is about, as it was when decided.
    public var link: Interaction {
        switch self {
        case .start(let due): due.link
        case .cancel(let link, _): link
        }
    }

    /// Whether `current`, the link as stored right now, is still the waiting
    /// link this decision was made for. The coordinator calls this inside the
    /// same serialized write that applies `.started` (or the cancel event),
    /// immediately before applying it. A link the owner opted out of (gone),
    /// or that already started, is never acted on from a stale hand-over.
    public func isCurrent(_ current: Interaction?) -> Bool {
        guard let current else { return false }
        return current.id == link.id && current.chain == link.chain && current.skill == link.skill
            && ChainPlanner.isWaitingForPlanEnd(current)
    }
}

/// Decides which waiting links start. Pure: the scheduler and tests drive it
/// with a clock.
public struct PlanEndSchedule: Sendable {
    public let planner: ChainPlanner

    public init(planner: ChainPlanner) { self.planner = planner }

    /// Every waiting link that is due at `now` or can never run.
    public func check(at now: Date, interactions: [Interaction], settings: SkillSettings, cards: [PeerID: AgentCard]) -> [ScheduledChain] {
        interactions.filter(ChainPlanner.isWaitingForPlanEnd).compactMap { link in
            check(link, at: now, interactions: interactions, settings: settings, cards: cards)
        }
    }

    /// The earliest plan end after `now` among waiting links, for the app to
    /// wake (or schedule a local notification) then. Ends already passed are
    /// `check`'s to report, so they never make a caller wake in a loop.
    public func nextEnd(after now: Date, interactions: [Interaction]) -> Date? {
        interactions.filter(ChainPlanner.isWaitingForPlanEnd).compactMap { link in
            interactions.first { $0.id == link.chain?.parent }?.plan?.endsAt
        }.filter { $0 > now }.min()
    }

    private func check(_ link: Interaction, at now: Date, interactions: [Interaction], settings: SkillSettings, cards: [PeerID: AgentCard]) -> ScheduledChain? {
        guard let chain = link.chain,
              let parent = interactions.first(where: { $0.id == chain.parent }),
              parent.conversation == chain.parentConversation,
              let plan = parent.plan, let end = plan.endsAt
        else { return .cancel(link, .withdrawn) }
        // The plan was called off before it happened.
        guard parent.state == .planned || parent.state == .done else { return .cancel(link, .withdrawn) }
        // Opted in at Confirm: the parent was already a plan when the owner
        // tapped. Anything else is not an opt-in this phone recorded.
        guard parent.history.contains(where: { $0.state == .planned && $0.at <= chain.optedInAt }) else { return .cancel(link, .withdrawn) }
        guard now >= end else { return nil }

        switch planner.registry.availability(of: link.skill.id, in: settings) {
        case .available: break
        case .blockedByPrivacy: return .cancel(link, .blockedByPrivacy)
        case .notInThisBuild, .turnedOff: return .cancel(link, .withdrawn)
        }
        // What the owner approved was this skill at this version.
        guard planner.registry.descriptor(for: link.skill.id)?.ref == link.skill else { return .cancel(link, .withdrawn) }
        for peer in link.participants {
            guard let card = cards[peer], card.support(for: link.skill).isSupported else { return .cancel(link, .unsupported) }
        }
        return .start(DueChain(link: link, parent: parent, plan: plan))
    }
}

/// Runs `PlanEndSchedule` while the app is open: wakes at the next plan end
/// (or every `maxNap`, so a newly saved opt-in is picked up), and hands what
/// is due to the app, which applies the events and starts the services.
/// Each link is handed over once per scheduler.
public actor PlanEndScheduler {
    private let schedule: PlanEndSchedule
    private let store: any InteractionStore
    private let settings: @Sendable () async -> SkillSettings
    private let cards: @Sendable () async -> [PeerID: AgentCard]
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let maxNap: Duration
    private var handedOver: Set<InteractionID> = []

    public init(
        schedule: PlanEndSchedule,
        store: any InteractionStore,
        settings: @escaping @Sendable () async -> SkillSettings,
        cards: @escaping @Sendable () async -> [PeerID: AgentCard],
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        maxNap: Duration = .seconds(60)
    ) {
        self.schedule = schedule
        self.store = store
        self.settings = settings
        self.cards = cards
        self.now = now
        self.sleep = sleep
        self.maxNap = maxNap
    }

    /// What is due now that has not been handed over yet. Call at launch and
    /// when the app comes to the foreground. Settings and cards are read
    /// first and the store last, with no suspension after it, so an opt-out
    /// made while settings or cards were loading is not missed. The coordinator
    /// still confirms each one with `claim` (or `ScheduledChain.isCurrent`)
    /// right before acting, because the owner can opt out after this returns.
    public func due() async throws -> [ScheduledChain] {
        let settings = await settings()
        let cards = await cards()
        let all = try await store.all()
        return schedule.check(at: now(), interactions: all, settings: settings, cards: cards)
            .filter { handedOver.insert($0.link.id).inserted }
    }

    /// The link as stored now, if `scheduled` still applies to it; nil if the
    /// owner opted out or it already started. For a coordinator whose store
    /// writes are not already serialized with this read, prefer
    /// `ScheduledChain.isCurrent` inside its own write.
    public func claim(_ scheduled: ScheduledChain) async throws -> Interaction? {
        let current = try await store.interaction(scheduled.link.id)
        return scheduled.isCurrent(current) ? current : nil
    }

    /// Checks, hands over, then sleeps until the next plan end or `maxNap`,
    /// until cancelled.
    public func run(_ handle: @Sendable ([ScheduledChain]) async -> Void) async {
        while !Task.isCancelled {
            if let results = try? await due(), !results.isEmpty { await handle(results) }
            let nap: Duration
            let current = now()
            if let all = try? await store.all(), let next = schedule.nextEnd(after: current, interactions: all) {
                let wait = next.timeIntervalSince(current)
                nap = min(.milliseconds(Int64((wait * 1000).rounded(.up))), maxNap)
            } else {
                nap = maxNap
            }
            do { try await sleep(nap) } catch { return }
        }
    }
}
