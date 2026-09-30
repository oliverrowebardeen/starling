import Foundation
import Observation
import StarlingCore

/// The app's `ConsentProvider`: turns each `Disclosure` the policy asks about
/// into a sheet, waits for the owner, and returns approved or declined.
///
/// Requests queue and are shown one at a time. Anything other than an
/// explicit approval is a decline: dismissing the sheet, the requesting
/// task being cancelled, or the owner not answering within `timeout`.
@MainActor
@Observable
public final class ConsentCoordinator: ConsentProvider {
    /// What the sheet shows for one request.
    public struct Request: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let recipientName: String
        /// The recipient agent's claimed model location, or nil if unknown.
        public let recipientModel: String?
        public let items: [DisplayLine]
        public let disclosure: Disclosure
    }

    public private(set) var current: Request?

    private struct Pending {
        let request: Request
        let continuation: CheckedContinuation<ConsentOutcome, Never>
    }

    private var queue: [Pending] = []
    private let peers: (any PairedPeerStore)?
    private let formatter: ValueFormatter
    private let timeout: Duration

    public init(peers: (any PairedPeerStore)?, formatter: ValueFormatter = ValueFormatter(), timeout: Duration = .seconds(120)) {
        self.peers = peers
        self.formatter = formatter
        self.timeout = timeout
    }

    public func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        let name: String
        if let peer = try? await peers?.peer(for: disclosure.recipient) {
            name = peer.nickname
        } else {
            name = "Someone you haven't paired with"
        }
        let request = Request(
            id: UUID(),
            recipientName: name,
            recipientModel: disclosure.recipientModel.map(formatter.locality),
            items: disclosure.items.map(formatter.disclosedItem),
            disclosure: disclosure
        )
        let id = request.id
        let timeout = timeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resolve(id, .declined)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancelled before the sheet could appear: onCancel already
                // ran and found nothing to resolve.
                guard !Task.isCancelled else { return continuation.resume(returning: .declined) }
                enqueue(Pending(request: request, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id, .declined) }
        }
    }

    /// The owner's answer to the request on screen.
    public func answer(_ outcome: ConsentOutcome) {
        guard let current else { return }
        resolve(current.id, outcome)
    }

    /// The sheet went away without an answer.
    public func dismissed(_ id: Request.ID) {
        resolve(id, .declined)
    }

    private func enqueue(_ pending: Pending) {
        queue.append(pending)
        if current == nil { current = pending.request }
    }

    private func resolve(_ id: Request.ID, _ outcome: ConsentOutcome) {
        guard let index = queue.firstIndex(where: { $0.request.id == id }) else { return }
        let pending = queue.remove(at: index)
        pending.continuation.resume(returning: outcome)
        if current?.id == id { current = queue.first?.request }
    }
}
