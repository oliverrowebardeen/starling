import Foundation
import StarlingCore
import StarlingFakes
import StarlingSwapPhotos
import Testing

/// Holds callers at one point until the test opens it, and lets the test
/// wait until a given number of callers have arrived. Deterministic: no
/// sleeps, no timing.
actor Gate {
    private var held: [CheckedContinuation<Void, Never>] = []
    private var arrivals = 0
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isOpen = false

    func pass() async {
        arrivals += 1
        let ready = watchers.filter { $0.count <= arrivals }
        watchers.removeAll { $0.count <= arrivals }
        for watcher in ready { watcher.continuation.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { held.append($0) }
    }

    /// Returns once `count` callers have reached `pass()`.
    func arrived(_ count: Int = 1) async {
        guard arrivals < count else { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }

    /// Lets the callers held now through; later ones are held again.
    func release() {
        for continuation in held { continuation.resume() }
        held = []
    }

    /// Lets everyone through from now on, so a regression fails instead of
    /// hanging on a later send.
    func open() {
        isOpen = true
        release()
    }
}

/// A consent sheet that stays up until the gate opens, then approves.
/// Like the real sheet, it does not end early when its task is cancelled.
actor GatedConsent: ConsentProvider {
    let gate = Gate()
    func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        await gate.pass()
        return .approved
    }
}

/// Asks for consent, then holds the Outbox's re-check after consent at the
/// gate.
actor GatedRecheckPolicy: PolicyEngine {
    let gate = Gate()
    private var seen: Set<MessageID> = []

    func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        let envelope = message.envelope
        let disclosure = Disclosure(recipient: envelope.recipient, recipientModel: nil, items: [],
                                    conversation: envelope.conversation, skill: envelope.skill)
        if seen.insert(envelope.id).inserted { return .needsConsent(disclosure) }
        await gate.pass()
        return .needsConsent(disclosure)
    }
}

extension Phone {
    init(policy: any PolicyEngine, consent: any ConsentProvider) {
        self.init { transport, ledger in
            Outbox(transport: transport, policy: policy, consent: consent, ledger: ledger, now: { Fixtures.afterTonight })
        }
    }
}

@Suite struct WithdrawalTests {
    static func pickInFlight(_ phone: Phone) async throws -> (SkillRequest, Task<Void, any Error>) {
        let request = Fixtures.request()
        try await phone.service.start(request)
        let answering = Task { try await phone.service.answer(request.interaction, with: .reply(question: 1, .count(3))) }
        return (request, answering)
    }

    static func lifecycle(_ events: [SkillEvent]) -> [InteractionEvent] {
        events.compactMap { if case .lifecycle(_, let event) = $0 { event } else { nil } }
    }

    @Test func withdrawingWhileTheConsentSheetIsUpSendsNothing() async throws {
        let consent = GatedConsent()
        let phone = Phone(policy: FixedPolicyEngine(.needsConsent(Disclosure(recipient: Fixtures.maya, recipientModel: nil, items: []))), consent: consent)
        let (request, answering) = try await Self.pickInFlight(phone)
        await consent.gate.arrived()
        await phone.service.withdraw(request.interaction)
        await consent.gate.open()
        _ = await answering.result
        #expect(await phone.transport.sent.isEmpty)
        // Withdrawn: no failure or anything else reported after the answer.
        #expect(Self.lifecycle(await phone.events()) == [.ownerNeeded(SwapPhotos.pickQuestion(revision: 1)), .ownerAnswered(question: 1)])
    }

    @Test func withdrawingDuringThePolicyRecheckSendsNothing() async throws {
        let policy = GatedRecheckPolicy()
        let phone = Phone(policy: policy, consent: ScriptedConsentProvider(.approved))
        let (request, answering) = try await Self.pickInFlight(phone)
        await policy.gate.arrived()
        await phone.service.withdraw(request.interaction)
        await policy.gate.open()
        _ = await answering.result
        #expect(await phone.transport.sent.isEmpty)
        #expect(Self.lifecycle(await phone.events()) == [.ownerNeeded(SwapPhotos.pickQuestion(revision: 1)), .ownerAnswered(question: 1)])
    }

    @Test func withdrawingBetweenOffersStopsTheRest() async throws {
        let consent = GatedConsent()
        let phone = Phone(policy: FixedPolicyEngine(.needsConsent(Disclosure(recipient: Fixtures.maya, recipientModel: nil, items: []))), consent: consent)
        let (request, answering) = try await Self.pickInFlight(phone)
        await consent.gate.arrived(1)
        await consent.gate.release()
        // Maya's offer went out; Jake's waits on its sheet.
        await consent.gate.arrived(2)
        await phone.service.withdraw(request.interaction)
        await consent.gate.open()
        _ = await answering.result
        #expect(await phone.transport.sent.map(\.peer) == [Fixtures.maya])
    }

    @Test func withdrawingAFriendsAcceptanceInFlightSendsNothing() async throws {
        let consent = GatedConsent()
        let phone = Phone(policy: FixedPolicyEngine(.needsConsent(Disclosure(recipient: Fixtures.maya, recipientModel: nil, items: []))), consent: consent)
        await phone.service.handle(.message(try Fixtures.offer()))
        var iterator = phone.service.events.makeAsyncIterator()
        guard case .incoming(let id, _, _, _) = await iterator.next() else {
            Issue.record("expected an incoming interaction")
            return
        }
        let accepting = Task { try await phone.service.answer(id, with: .accept(proposal: 1)) }
        await consent.gate.arrived()
        await phone.service.withdraw(id)
        await consent.gate.open()
        _ = await accepting.result
        #expect(await phone.transport.sent.isEmpty)
        // Only the proposal card, which followed .incoming; no acceptance.
        #expect(Self.lifecycle(await phone.events()).count == 1)
    }

    @Test func shuttingDownCancelsSendsInFlight() async throws {
        let policy = GatedRecheckPolicy()
        let phone = Phone(policy: policy, consent: ScriptedConsentProvider(.approved))
        let (_, answering) = try await Self.pickInFlight(phone)
        await policy.gate.arrived()
        await phone.service.shutdown()
        await policy.gate.open()
        _ = await answering.result
        #expect(await phone.transport.sent.isEmpty)
    }

    @Test func withdrawingCancelsEveryAcceptanceInFlightNotOnlyTheLatest() async throws {
        let policy = GatedRecheckPolicy()
        let phone = Phone(policy: policy, consent: ScriptedConsentProvider(.approved))
        let conversation = ConversationID()
        await phone.service.handle(.message(try Fixtures.offer(count: 5, conversation: conversation)))
        var iterator = phone.service.events.makeAsyncIterator()
        guard case .incoming(let id, _, _, _) = await iterator.next() else {
            Issue.record("expected an incoming interaction")
            return
        }
        // Accept offer 1; its send waits in the policy re-check.
        let service = phone.service
        let first = Task { try await service.answer(id, with: .accept(proposal: 1)) }
        await policy.gate.arrived(1)
        // A newer offer replaces the card; accept it too, and it waits as well.
        await phone.service.handle(.message(try Fixtures.offer(count: 2, conversation: conversation)))
        let second = Task { try await service.answer(id, with: .accept(proposal: 2)) }
        await policy.gate.arrived(2)
        await phone.service.withdraw(id)
        await policy.gate.open()
        _ = await first.result
        _ = await second.result
        // Neither acceptance leaves.
        #expect(await phone.transport.sent.isEmpty)
    }
}
