import Foundation
import StarlingCore

// How a starter's proposal reaches a friend (final privacy review of PR
// #56, finding 1): on a schedule fixed when it is first sent. It is resent
// with backoff until the owner window ends, whatever the starter's owner
// does meanwhile: passing or saying I'm in. It stops early only when that
// friend says I'm in itself. So a friend can
// never count its way to the starter's answer.

/// One proposal on its way to one friend.
struct Delivery: Sendable {
    let request: InteractionID
    /// What the friend's I'm in must name to stop it.
    let terms: Terms
    let body: MessageBody
    let chainedFrom: ConversationID?
    let mode: SendMode
    /// Every envelope that carried it, so an I'm in naming any of them counts.
    var envelopes: [MessageID] = []
    var task: Task<Void, Never>?
}

extension DownForService {
    /// Sends `proposal` to the friend at `key` now and on the fixed
    /// schedule after, replacing any earlier delivery to it.
    func startDelivery(_ proposal: Proposal, to key: RunKey, for id: InteractionID, chainedFrom: ConversationID?, mode: SendMode) {
        deliveries[key]?.task?.cancel()
        var delivery = Delivery(request: id, terms: proposal.terms, body: .propose(proposal), chainedFrom: chainedFrom, mode: mode)
        let window = configuration.ownerWindow
        let first = configuration.retryInterval
        let cap = configuration.maxBackoff
        delivery.task = Task { [weak self] in
            await self?.enqueue(.deliver(key), for: key.peer)
            var elapsed: Duration = .zero
            var wait = first
            while elapsed + wait <= window {
                do { try await Task.sleep(for: wait) } catch { return }
                elapsed += wait
                await self?.enqueue(.deliver(key), for: key.peer)
                wait = min(wait * 2, cap)
            }
            await self?.deliveryEnded(key)
        }
        deliveries[key] = delivery
    }

    /// One send of a delivery, on the friend's queue. Through the run's own
    /// checks while the run is live, otherwise straight to the Outbox for
    /// the request (which must still be live: nothing leaves for one that
    /// ended).
    func sendDelivery(_ key: RunKey) async {
        guard let delivery = deliveries[key], requests[delivery.request] != nil else { return }
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
        deliveries.removeValue(forKey: key)?.task?.cancel()
    }

    private func deliveryEnded(_ key: RunKey) {
        deliveries[key] = nil
    }

    /// Whether `acceptance` from the friend at `key` names a delivered
    /// proposal, as it was delivered.
    func acceptsDelivery(_ acceptance: Acceptance, at key: RunKey) -> Bool {
        guard let delivery = deliveries[key] else { return false }
        return acceptance.terms == delivery.terms && (delivery.envelopes.contains(acceptance.proposal) || runs[key]?.proposalEnvelopes.contains(acceptance.proposal) == true)
    }
}
