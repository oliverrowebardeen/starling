import Foundation
import Observation
import StarlingCore

/// The app's `ConsentProvider`: turns each `Disclosure` the policy asks about
/// into a sheet, waits for the owner, and returns approved or declined.
///
/// Requests queue and are shown one at a time. Anything other than an
/// explicit approval is a decline: dismissing the sheet, the requesting
/// task being cancelled, or the owner not answering within `timeout`.
///
/// Approvals are remembered for `approvalMemory` (ADR 0142): a request whose
/// `Disclosure` equals one the owner approved in that window (same
/// recipient, same claimed model location, identical items) is approved
/// without a sheet, so negotiation retries of the same step do not ask
/// again. Declines, timeouts, and cancellations are never remembered.
/// `forgetApprovals()` clears the memory; the app calls it whenever the
/// Down intent changes, so an approval never outlives its intent.
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
    /// When each remembered disclosure was approved.
    private var approvals: [Disclosure: Date] = [:]
    private let peers: (any PairedPeerStore)?
    private let formatter: ValueFormatter
    private let timeout: Duration
    private let approvalMemory: Duration
    private let now: @Sendable () -> Date

    public init(
        peers: (any PairedPeerStore)?,
        formatter: ValueFormatter = ValueFormatter(),
        timeout: Duration = .seconds(120),
        approvalMemory: Duration = .seconds(600),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.peers = peers
        self.formatter = formatter
        self.timeout = timeout
        self.approvalMemory = approvalMemory
        self.now = now
    }

    /// Clears remembered approvals. Pending requests are unaffected.
    public func forgetApprovals() {
        approvals.removeAll()
    }

    public func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        if isRemembered(disclosure) { return .approved }
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

    /// The owner's answer to the request on screen. It also answers any
    /// queued request for the identical disclosure (a retry that arrived
    /// while the sheet was open); only an approval is kept for later.
    public func answer(_ outcome: ConsentOutcome) {
        guard let current else { return }
        if outcome == .approved { approvals[current.disclosure] = now() }
        for pending in queue where pending.request.disclosure == current.disclosure {
            resolve(pending.request.id, outcome)
        }
    }

    /// The sheet went away without an answer.
    public func dismissed(_ id: Request.ID) {
        resolve(id, .declined)
    }

    private func isRemembered(_ disclosure: Disclosure) -> Bool {
        guard let approvedAt = approvals[disclosure] else { return false }
        let window = Double(approvalMemory.components.seconds) + Double(approvalMemory.components.attoseconds) / 1e18
        guard now().timeIntervalSince(approvedAt) < window else {
            approvals[disclosure] = nil
            return false
        }
        return true
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
