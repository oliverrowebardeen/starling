import Foundation
import StarlingCore
import Synchronization

/// Wraps the app's `ConsentProvider` so a consent sheet for a Down for...
/// send shows on that request's lifecycle: `consentNeeded` when the sheet
/// opens, `consentGiven` when the owner approves, and the request ends as
/// declined on "Don't send" (ADR 0011, amendment 8).
///
/// The Outbox owns the sheet and the service cannot see it, so this is the
/// only point that knows a sheet is up. Disclosures of other skills pass
/// straight through, so relays for several skills can wrap each other.
///
/// Build it first, give it to the Outbox, then `attach` the service:
///
///     let relay = DownForConsentRelay(wrapping: consentSheet)
///     let outbox = Outbox(transport: link, policy: policy, consent: relay)
///     let downFor = DownForService(localPeer: me, outbox: outbox, ...)
///     relay.attach(downFor)
public final class DownForConsentRelay: ConsentProvider, Sendable {
    private let base: any ConsentProvider
    private let service = Mutex<DownForService?>(nil)

    public init(wrapping base: any ConsentProvider) {
        self.base = base
    }

    public func attach(_ service: DownForService) {
        self.service.withLock { $0 = service }
    }

    public func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        let service = self.service.withLock { $0 }
        guard let service, disclosure.skill?.id == DownFor.ref.id else { return await base.requestConsent(for: disclosure) }
        let ticket = await service.consentWillStart(disclosure)
        let outcome = await base.requestConsent(for: disclosure)
        if let ticket { await service.consentDidEnd(ticket, outcome) }
        return outcome
    }
}
