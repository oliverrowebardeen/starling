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
        // The policy judged the draft: the same message, before its number
        // and send time were set.
        #expect(await policy.evaluated.map(\.envelope.id) == [envelope.id])
        #expect(await policy.evaluated.map(\.envelope.body) == [envelope.body])
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
        let start = UInt64(Fixtures.now.timeIntervalSince1970 * 1000)
        let outbox = Outbox(transport: RecordingTransport(localPeer: Fixtures.alice), policy: FixedPolicyEngine(.allow),
                            consent: ScriptedConsentProvider(.approved), now: { Fixtures.now })
        let other = ConversationID()

        let first = try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
        let second = try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
        let elsewhere = try await outbox.send(body, to: Fixtures.bob, conversation: other)

        #expect([first.sequence, second.sequence, elsewhere.sequence] == [start, start + 1, start])
    }

    /// Review of PR #57: the clock moved back before the relaunch. The
    /// store keeps the numbers rising, so the friend drops nothing.
    @Test func aRelaunchAfterTheClockMovedBackStillRises() async throws {
        let inbox = Inbox(localPeer: Fixtures.bob, now: { Fixtures.now })
        let store = InMemorySentSequenceStore()
        for (launch, offset) in [(0, 0.0), (1, -60.0)] {
            let transport = RecordingTransport(localPeer: Fixtures.alice)
            let launchedAt = Fixtures.now.addingTimeInterval(offset)
            let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                                sequences: store, now: { launchedAt })
            for _ in 0..<5 { try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation) }
            for sent in await transport.sent {
                guard case .success = await inbox.accept(sent.frame, from: Fixtures.alice) else {
                    Issue.record("launch \(launch) had a frame dropped")
                    return
                }
            }
        }
        #expect(store.highestSent(in: Fixtures.conversation) == UInt64(Fixtures.now.timeIntervalSince1970 * 1000) + 9)
    }

    /// Re-review of PR #57: never wrap or repeat at the top of the range,
    /// and never send a number the store failed to record.
    @Test func numbersThatCannotBeRecordedOrWouldRepeatAreNeverSent() async throws {
        for seeded in [UInt64.max - 1, .max] {
            let transport = RecordingTransport(localPeer: Fixtures.alice)
            let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                                sequences: InMemorySentSequenceStore([Fixtures.conversation: seeded]), now: { Fixtures.now })
            await #expect(throws: OutboxError.sequenceExhausted) {
                try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
            }
            #expect(await transport.sent.isEmpty)
        }
        let store = InMemorySentSequenceStore()
        store.failWrites()
        let transport = RecordingTransport(localPeer: Fixtures.alice)
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                            sequences: store, now: { Fixtures.now })
        await #expect(throws: InMemorySentSequenceStore.WriteFailed.self) {
            try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
        }
        #expect(await transport.sent.isEmpty)
    }

    /// Lane C: a relaunched app restarted at 0, and the friend's Inbox
    /// dropped every number it had already seen as a replay.
    @Test func aRelaunchedOutboxNeverReusesANumberTheFriendSaw() async throws {
        let inbox = Inbox(localPeer: Fixtures.bob, now: { Fixtures.now })
        var clock = Fixtures.now
        for launch in 0..<2 {
            let transport = RecordingTransport(localPeer: Fixtures.alice)
            let launchedAt = clock
            let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved),
                                now: { launchedAt })
            for _ in 0..<70 { try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation) }
            for sent in await transport.sent {
                guard case .success = await inbox.accept(sent.frame, from: Fixtures.alice) else {
                    Issue.record("launch \(launch) had a frame dropped")
                    return
                }
            }
            clock = clock.addingTimeInterval(1)
        }
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

    /// Review of PR #53: a refused send must leave no gap in the numbers,
    /// or the friend learns that something was refused (with Time set to
    /// Never, that their slot was free).
    @Test func aRefusedSendConsumesNoSequenceNumber() async throws {
        let start = UInt64(Fixtures.now.timeIntervalSince1970 * 1000)
        for refusal in [PolicyDecision.deny(PolicyViolation(rule: "never")), .needsConsent(try disclosure(100))] {
            let transport = RecordingTransport(localPeer: Fixtures.alice)
            let refused = Outbox(transport: transport, policy: SequencedPolicyEngine([refusal, .allow]),
                                 consent: ScriptedConsentProvider(.declined), now: { Fixtures.now })
            _ = try? await refused.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
            let sent = try await refused.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
            #expect(sent.sequence == start)
            #expect(await transport.sent.count == 1)
        }
    }

    /// The send time is when the envelope leaves, not when it was drafted:
    /// a consent sheet answered after the receiver's age limit must not
    /// make the friend drop the envelope.
    @Test func theSendTimeIsTakenAfterConsent() async throws {
        let clock = Clock(Fixtures.now)
        let outbox = Outbox(transport: RecordingTransport(localPeer: Fixtures.alice), policy: FixedPolicyEngine(.needsConsent(try disclosure(100))),
                            consent: AdvancingConsent(clock: clock, by: 900), now: { clock.now })
        let sent = try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
        #expect(sent.sentAt == Timestamp(Fixtures.now.addingTimeInterval(900)))
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

    /// Lane E: the audit lists a send allowed without a sheet in the
    /// policy's own terms, and says so when the policy cannot.
    @Test func observerHearsWhatEachSendDisclosed() async throws {
        let sheet = try disclosure(100)
        let policyItems = try disclosure(200)
        for (policy, expected) in [
            (FixedPolicyEngine(.needsConsent(sheet)), sheet.items as [DisclosedItem]?),
            (FixedPolicyEngine(.allow, explain: { _ in policyItems }), policyItems.items),
            (FixedPolicyEngine(.allow), nil),
        ] {
            let observer = RecordingOutboxObserver()
            let outbox = Outbox(transport: RecordingTransport(localPeer: Fixtures.alice), policy: policy,
                                consent: ScriptedConsentProvider(.approved), observer: observer)
            try await outbox.send(body, to: Fixtures.bob, conversation: Fixtures.conversation)
            #expect(await observer.records.map(\.disclosed) == [expected])
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

/// A clock a test can move from inside a consent sheet.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(by seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

/// Approves after the owner "took" `seconds` to decide.
struct AdvancingConsent: ConsentProvider {
    let clock: Clock
    let by: TimeInterval
    func requestConsent(for disclosure: Disclosure) async -> ConsentOutcome {
        clock.advance(by: by)
        return .approved
    }
}
