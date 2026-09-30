import Foundation
import StarlingCore
import StarlingFakes
import StarlingPolicy
import StarlingTransport
import Testing

@Suite(.timeLimit(.minutes(1))) struct OutboxTests {
    @Test func neverBlocksBeforeConsentOrTransport() async throws {
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let consent = ScriptedConsentProvider(.approved)
        let log = try InMemoryAuditLog()
        let outbox = AuditedOutbox(outbox: Outbox(transport: transport, policy: Fixtures.engine(action: .never), consent: consent), auditLog: log)
        await #expect(throws: OutboxError.denied(PolicyViolation(rule: PolicyRuleID.never, issue: .activity))) {
            try await outbox.send(Fixtures.body(.query), to: Fixtures.bob.id, conversation: Fixtures.conversation, recipientCard: Fixtures.card)
        }
        #expect(await consent.requests.isEmpty)
        #expect(await transport.sent.isEmpty)
        #expect(await log.entries().isEmpty)
    }

    @Test func askEachTimeWaitsAndApprovalsAreNotReused() async throws {
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let consent = PendingConsent()
        let log = try InMemoryAuditLog()
        let outbox = AuditedOutbox(outbox: Outbox(transport: transport, policy: Fixtures.engine(action: .askEachTime), consent: consent), auditLog: log)
        var requests = consent.requests.makeAsyncIterator()
        for index in 0..<2 {
            let send = Task {
                try await outbox.send(Fixtures.body(.query), to: Fixtures.bob.id, conversation: Fixtures.conversation, recipientCard: Fixtures.card)
            }
            let disclosure = try #require(await requests.next())
            #expect(disclosure.items == [DisclosedItem(category: .interest, issue: .activity, value: Fixtures.value)])
            #expect(await transport.sent.count == index)
            #expect(await log.entries().count == index)
            await consent.resolve(.approved)
            let sent = try await send.value
            #expect(await transport.sent.count == index + 1)
            #expect(await log.entries().last?.message == sent.id)
        }
    }

    @Test func loopbackOnlyDeliversTheApprovedMessageThroughInbox() async throws {
        let hub = LoopbackHub()
        let alice = LoopbackTransport(localPeer: Fixtures.alice, hub: hub)
        let bob = LoopbackTransport(localPeer: Fixtures.bob.id, hub: hub)
        try await alice.start()
        try await bob.start()
        let inbox = Inbox(localPeer: Fixtures.bob.id)
        let incoming = inbox.events(from: bob)
        let received = Task {
            var envelopes: [Envelope] = []
            for await event in incoming {
                if case .message(let envelope) = event { envelopes.append(envelope) }
            }
            return envelopes
        }
        let consent = PendingConsent()
        let denied = Outbox(transport: alice, policy: Fixtures.engine(action: .never), consent: consent)
        await #expect(throws: OutboxError.denied(PolicyViolation(rule: PolicyRuleID.never, issue: .activity))) {
            try await denied.send(Fixtures.body(.query), to: Fixtures.bob.id, conversation: Fixtures.conversation, recipientCard: Fixtures.card)
        }
        let log = try InMemoryAuditLog()
        let allowed = AuditedOutbox(outbox: Outbox(transport: alice, policy: Fixtures.engine(action: .askEachTime), consent: consent), auditLog: log)
        let send = Task {
            try await allowed.send(Fixtures.body(.query), to: Fixtures.bob.id, conversation: Fixtures.conversation, recipientCard: Fixtures.card)
        }
        var requests = consent.requests.makeAsyncIterator()
        _ = try #require(await requests.next())
        #expect(await log.entries().isEmpty)
        await consent.resolve(.approved)
        let envelope = try await send.value
        await bob.stop()
        await alice.stop()
        #expect(await received.value == [envelope])
        #expect(await log.entries().map(\.message) == [envelope.id])
    }

    @Test func declinedAndFailedSendsAreNotAudited() async throws {
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let log = try InMemoryAuditLog()
        let declined = AuditedOutbox(outbox: Outbox(transport: transport, policy: Fixtures.engine(), consent: ScriptedConsentProvider(.declined)), auditLog: log)
        await #expect(throws: OutboxError.consentDeclined) {
            try await declined.send(Fixtures.body(.query), to: Fixtures.bob.id, conversation: Fixtures.conversation, recipientCard: Fixtures.card)
        }
        #expect(await transport.sent.isEmpty)
        let accepted = AuditedOutbox(outbox: Outbox(transport: transport, policy: Fixtures.engine(), consent: ScriptedConsentProvider(.approved)), auditLog: log)
        await transport.failSends(with: .peerUnreachable(Fixtures.bob.id))
        await #expect(throws: TransportError.peerUnreachable(Fixtures.bob.id)) {
            try await accepted.send(Fixtures.body(.query), to: Fixtures.bob.id, conversation: Fixtures.conversation, recipientCard: Fixtures.card)
        }
        #expect(await log.entries().isEmpty)
    }

    @Test func cloudCardIsRefusedEndToEndUnderStrictSetting() async throws {
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let consent = ScriptedConsentProvider(.approved)
        let outbox = Outbox(transport: transport, policy: Fixtures.engine(onlyOnDevice: true), consent: consent)
        await #expect(throws: OutboxError.denied(PolicyViolation(rule: PolicyRuleID.onDeviceOnly))) {
            try await outbox.send(Fixtures.body(.query), to: Fixtures.bob.id, conversation: Fixtures.conversation,
                                  recipientCard: AgentCard(model: .thirdPartyCloud(provider: "example"), capabilities: [.down]))
        }
        #expect(await consent.requests.isEmpty)
        #expect(await transport.sent.isEmpty)
    }

    @Test func nonPrivatePSIStepCannotSkipConsentOrNeverRules() async throws {
        for action in [DisclosureRule.Action.never, .allowOnDevicePeers] {
            let engine = Fixtures.engine(action: action)
            try await Fixtures.registerContext(engine)
            let transport = RecordingTransport(localPeer: Fixtures.alice)
            let consent = ScriptedConsentProvider(.declined)
            let outbox = Outbox(transport: transport, policy: engine, consent: consent)
            let expected: OutboxError = action == .never
                ? .denied(PolicyViolation(rule: PolicyRuleID.never, issue: .activity)) : .consentDeclined
            await #expect(throws: expected) {
                try await outbox.send(Fixtures.body(.psi), to: Fixtures.bob.id, conversation: Fixtures.conversation, recipientCard: Fixtures.card)
            }
            #expect(await consent.requests.count == (action == .never ? 0 : 1))
            #expect(await transport.sent.isEmpty)
        }
    }
}

/// A deterministic gate: request arrival proves the send is suspended, with
/// no sleeps, polling, or assumption about scheduler timing.
private actor PendingConsent: ConsentProvider {
    nonisolated let requests: AsyncStream<Disclosure>
    private let stream: AsyncStream<Disclosure>.Continuation
    private var pending: CheckedContinuation<ConsentOutcome, Never>?

    init() { (requests, stream) = AsyncStream.makeStream(of: Disclosure.self) }

    func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        await withCheckedContinuation { continuation in
            precondition(pending == nil)
            pending = continuation
            stream.yield(disclosure)
        }
    }

    func resolve(_ outcome: ConsentOutcome) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: outcome)
    }
}
