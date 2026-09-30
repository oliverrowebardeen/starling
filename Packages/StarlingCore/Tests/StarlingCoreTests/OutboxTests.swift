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
}
