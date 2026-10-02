import Foundation
import StarlingCore

// How a starter's proposal reaches a friend (final privacy review of PR
// #56, finding 1): on a schedule fixed when it is first sent. It is resent
// with backoff until the owner window ends, whatever the starter's owner
// does meanwhile: passing or saying I'm in. It stops early only when that
// friend says I'm in itself. So a friend can never count its way to the
// starter's answer.

/// One proposal on its way to one friend.
struct Delivery: Sendable {
    /// Which delivery a queued send belongs to.
    let generation = UUID()
    let request: InteractionID
    /// What the friend's I'm in must name to stop it.
    let terms: Terms
    let body: MessageBody
    let chainedFrom: ConversationID?
    let mode: SendMode
    /// Every envelope that carried it, so an I'm in naming any of them counts.
    var envelopes: [MessageID] = []
    /// One per scheduled send, cancelled when the delivery stops.
    var tasks: [Task<Void, Never>] = []
}

extension DownForService {
    /// Sends `proposal` to the friend at `key` now and on the fixed
    /// schedule after, replacing any earlier delivery to it.
    func startDelivery(_ proposal: Proposal, to key: RunKey, for id: InteractionID, chainedFrom: ConversationID?, mode: SendMode) {
        for task in deliveries[key]?.tasks ?? [] { task.cancel() }
        var delivery = Delivery(request: id, terms: proposal.terms, body: .propose(proposal), chainedFrom: chainedFrom, mode: mode)
        let generation = delivery.generation
        let schedule = Self.deliverySchedule(window: configuration.ownerWindow, first: configuration.retryInterval, cap: configuration.maxBackoff)
        // Every send's time is fixed now, from the start, on the service's
        // clock: none waits on the one before it.
        for (index, offset) in schedule.enumerated() {
            let last = index == schedule.count - 1
            delivery.tasks.append(Task { [weak self, clock] in
                if offset > .zero {
                    do { try await clock.sleep(offset) } catch { return }
                }
                await self?.enqueue(.deliver(key, generation, last: last), for: key.peer)
            })
        }
        deliveries[key] = delivery
    }

    /// One send of a delivery, on the friend's queue. Through the run's own
    /// checks while the run is live, otherwise straight to the Outbox for
    /// the request (which must still be live: nothing leaves for one that
    /// ended).
    ///
    /// The delivery stays until its last scheduled send has run here, so a
    /// send still waiting behind another on the queue is not lost (lane
    /// F's #76). A send left over from a delivery since replaced is dropped.
    func sendDelivery(_ key: RunKey, _ generation: UUID, last: Bool) async {
        guard let delivery = deliveries[key], delivery.generation == generation else { return }
        defer { if last, deliveries[key]?.generation == generation { deliveries[key] = nil } }
        guard requests[delivery.request] != nil else { return }
        if let run = runs[key], run.request == delivery.request, run.terms == delivery.terms {
            _ = await send(delivery.body, in: key)
            return
        }
        // Only while the plan is still ahead, as for any replay.
        if let start = Self.planStart(of: delivery.body), !DownForProfile.hasNotStarted(start, now: clock.now()) { return }
        let card = cards[key.peer]
        let body = delivery.body
        let context = OutboundContext(interaction: delivery.request)
        let (mode, chainedFrom) = (delivery.mode, delivery.chainedFrom)
        let result = await cancellable(run: nil, request: delivery.request) { [outbox] in
            try await outbox.send(body, to: key.peer, conversation: key.conversation, recipientCard: card, context: context, skill: DownFor.ref, mode: mode, chainedFrom: chainedFrom)
        }
        if case .success(let envelope) = result { deliveries[key]?.envelopes.append(envelope.id) }
    }

    /// The friend said I'm in to what was delivered: stop resending.
    func stopDelivery(_ key: RunKey) {
        for task in deliveries.removeValue(forKey: key)?.tasks ?? [] { task.cancel() }
    }

    /// When a proposal is sent, from its first send: at once, then after
    /// waits that start at `first` and double up to `cap`, for as long as
    /// `window` allows.
    static func deliverySchedule(window: Duration, first: Duration, cap: Duration) -> [Duration] {
        var schedule: [Duration] = [.zero]
        var wait = first
        while schedule.last! + wait <= window {
            schedule.append(schedule.last! + wait)
            wait = min(wait * 2, cap)
        }
        return schedule
    }

    /// Whether `acceptance` from the friend at `key` names a delivered
    /// proposal, as it was delivered.
    func acceptsDelivery(_ acceptance: Acceptance, at key: RunKey) -> Bool {
        guard let delivery = deliveries[key] else { return false }
        return acceptance.terms == delivery.terms && (delivery.envelopes.contains(acceptance.proposal) || runs[key]?.proposalEnvelopes.contains(acceptance.proposal) == true)
    }
}
