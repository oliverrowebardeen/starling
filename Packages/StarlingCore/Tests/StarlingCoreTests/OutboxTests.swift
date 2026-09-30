import Foundation
import StarlingCore
import StarlingFakes
import Testing

@Suite struct OutboxTests {
    let body = MessageBody.reject(Rejection(proposal: Fixtures.messageID, reason: .declinedByOwner))

    @Test func allowedMessagesAreEncodedAndSent() async throws {
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let policy = FixedPolicyEngine(.allow)
        let outbox = Outbox(transport: transport, policy: policy, consent: ScriptedConsentProvider(.declined), now: { Fixtures.now })

        let envelope = try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)

        let sent = await transport.sent
        #expect(sent.count == 1)
        #expect(sent.first?.peer == Fixtures.bob)
        #expect(try EnvelopeCodec().decode(#require(sent.first).frame.bytes) == envelope)
        #expect(envelope.sender == Fixtures.alice)
        #expect(await policy.evaluated.map(\.envelope) == [envelope])
    }

    @Test func deniedMessagesNeverReachTheTransport() async throws {
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let violation = PolicyViolation(rule: "never-share-place", issue: .place)
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.deny(violation)), consent: ScriptedConsentProvider(.approved))

        await #expect(throws: OutboxError.denied(violation)) {
            try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
        }
        #expect(await transport.sent.isEmpty)
    }

    @Test func consentIsRequiredWhenPolicyAsks() async throws {
        let disclosure = Disclosure(recipient: Fixtures.bob, recipientModel: .onDevice, items: [
            DisclosedItem(category: .terms, issue: .budget, value: .amount(try MoneyAmount(minorUnits: 1500))),
        ])
        for (outcome, expectedSends) in [(ConsentOutcome.declined, 0), (.approved, 1)] {
            let transport = RecordingTransport(localPeer: Fixtures.alice)
            let consent = ScriptedConsentProvider(outcome)
            let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.needsConsent(disclosure)), consent: consent)

            if outcome == .declined {
                await #expect(throws: OutboxError.consentDeclined) {
                    try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
                }
            } else {
                try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
            }
            #expect(await consent.requests == [disclosure])
            #expect(await transport.sent.count == expectedSends)
        }
    }

    @Test func sequenceNumbersIncreasePerConversation() async throws {
        let outbox = Outbox(transport: RecordingTransport(localPeer: Fixtures.alice), policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved))
        let other = ConversationID()

        let first = try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
        let second = try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
        let elsewhere = try await outbox.send(body, to: Fixtures.bob, conversation: other)

        #expect([first.sequence, second.sequence, elsewhere.sequence] == [0, 1, 0])
    }

    @Test func transportFailuresPropagate() async throws {
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        await transport.failSends(with: .peerUnreachable(Fixtures.bob))
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved))

        await #expect(throws: TransportError.peerUnreachable(Fixtures.bob)) {
            try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
        }
    }
}

/// Returns the scripted decisions in order, then repeats the last one.
actor SequencedPolicyEngine: PolicyEngine {
    private var decisions: [PolicyDecision]
    private(set) var evaluated: [OutboundMessage] = []

    init(_ decisions: [PolicyDecision]) { self.decisions = decisions }

    func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        evaluated.append(message)
        return decisions.count > 1 ? decisions.removeFirst() : decisions[0]
    }
}

/// Holds a consent request open until the test releases it.
actor GatedConsent: ConsentProvider {
    private var pending: CheckedContinuation<ConsentOutcome, Never>?
    private(set) var asked = false

    func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        asked = true
        return await withCheckedContinuation { pending = $0 }
    }

    func release(_ outcome: ConsentOutcome) {
        pending?.resume(returning: outcome)
        pending = nil
    }
}

/// Answers the first evaluation at once and holds the second until released.
actor GatedSecondEvaluationPolicy: PolicyEngine {
    private let decision: PolicyDecision
    private var calls = 0
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var secondStarted = false

    init(_ decision: PolicyDecision) { self.decision = decision }

    func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        calls += 1
        if calls == 2 {
            secondStarted = true
            await withCheckedContinuation { pending = $0 }
        }
        return decision
    }

    func release() {
        pending?.resume()
        pending = nil
    }
}

@Suite struct OutboxV11Tests {
    let body = MessageBody.reject(Rejection(proposal: Fixtures.messageID, reason: .declinedByOwner))

    func disclosure(_ cents: Int64) throws -> Disclosure {
        Disclosure(recipient: Fixtures.bob, recipientModel: .onDevice, items: [
            DisclosedItem(category: .terms, issue: .budget, value: .amount(try MoneyAmount(minorUnits: cents))),
        ])
    }

    @Test func localContextReachesThePolicyButNotTheWire() async throws {
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let policy = FixedPolicyEngine(.allow)
        let outbox = Outbox(transport: transport, policy: policy, consent: ScriptedConsentProvider(.declined))
        let context = OutboundContext(psi: .init(provider: InsecurePSIStub().descriptor, inputs: [.activity: .keywords([try Keyword("boba")])]))

        try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation, context: context)

        #expect(await policy.evaluated.first?.context == context)
        let wire = String(decoding: try #require(await transport.sent.first).frame.bytes, as: UTF8.self)
        #expect(!wire.contains("boba"))
    }

    @Test func observerHearsOnlySuccessfulSends() async throws {
        let violation = PolicyViolation(rule: "deny")
        for (decision, consent, fails, expected) in [
            (PolicyDecision.allow, ConsentOutcome.declined, false, 1),
            (.deny(violation), .approved, false, 0),
            (.needsConsent(try disclosure(100)), .declined, false, 0),
            (.allow, .approved, true, 0),
        ] {
            let transport = RecordingTransport(localPeer: Fixtures.alice)
            if fails { await transport.failSends(with: .peerUnreachable(Fixtures.bob)) }
            let observer = RecordingOutboxObserver()
            let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(decision), consent: ScriptedConsentProvider(consent), observer: observer)
            _ = try? await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
            let records = await observer.records
            #expect(records.count == expected)
            if expected == 1 { #expect(records.first?.decision == decision) }
        }
    }

    @Test func policyIsRecheckedAfterConsent() async throws {
        let first = try disclosure(1_000)
        let violation = PolicyViolation(rule: "rules-changed")
        for (second, expected) in [
            (PolicyDecision.needsConsent(first), nil as OutboxError?),
            (.allow, nil),
            (.deny(violation), .denied(violation)),
            (.needsConsent(try disclosure(9_000)), .policyChangedDuringConsent),
        ] {
            let transport = RecordingTransport(localPeer: Fixtures.alice)
            let outbox = Outbox(transport: transport, policy: SequencedPolicyEngine([.needsConsent(first), second]), consent: ScriptedConsentProvider(.approved))
            if let expected {
                await #expect(throws: expected) { try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation) }
                #expect(await transport.sent.isEmpty)
            } else {
                try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
                #expect(await transport.sent.count == 1)
            }
        }
    }

    /// Cancelled while the post-consent policy check is still running: the
    /// check passes, but nothing may be sent.
    @Test(.timeLimit(.minutes(1)))
    func cancellationDuringThePolicyRecheckSendsNothing() async throws {
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let policy = GatedSecondEvaluationPolicy(.needsConsent(try disclosure(500)))
        let outbox = Outbox(transport: transport, policy: policy, consent: ScriptedConsentProvider(.approved))
        let body = body
        let send = Task { try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation) }
        while !(await policy.secondStarted) { await Task.yield() }

        send.cancel()
        await policy.release()

        await #expect(throws: CancellationError.self) { try await send.value }
        #expect(await transport.sent.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationWhileAwaitingConsentSendsNothing() async throws {
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let consent = GatedConsent()
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.needsConsent(try disclosure(500))), consent: consent)
        let body = body
        let send = Task { try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation) }
        while !(await consent.asked) { await Task.yield() }

        send.cancel()
        await consent.release(.approved)

        await #expect(throws: CancellationError.self) { try await send.value }
        #expect(await transport.sent.isEmpty)
    }
}
