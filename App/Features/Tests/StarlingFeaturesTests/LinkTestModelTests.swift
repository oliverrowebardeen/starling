import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

@MainActor
@Suite struct LinkTestModelTests {
    let transport = RecordingTransport()
    let friend = PeerID.random()
    let card = try! AgentCard(model: .onDevice, capabilities: [.down])

    func model() -> LinkTestModel {
        let friend = friend
        return LinkTestModel(
            transport: transport,
            policy: FixedPolicyEngine(.allow),
            consent: ScriptedConsentProvider(.declined),
            observer: nil,
            card: card,
            name: { $0 == friend ? "Maya" : nil }
        )
    }

    func sentEnvelopes() async throws -> [Envelope] {
        try await transport.sent.map { try EnvelopeCodec().decode($0.frame.bytes) }
    }

    func inject(_ body: MessageBody, conversation: ConversationID, sequence: UInt64 = 0) throws {
        let envelope = try Envelope(conversation: conversation, sender: friend, recipient: transport.localPeer,
                                    sequence: sequence, sentAt: Timestamp(Date()), body: body)
        transport.inject(.received(try Frame(EnvelopeCodec().encode(envelope)), from: friend))
    }

    @Test func showsEachPeerOnceWithItsConnectionState() async {
        let model = model()
        await model.start()
        #expect(model.status == .running)
        transport.inject(.peerAvailable(friend))
        await eventually { model.peers.first?.isConnected == true }
        #expect(model.peers.map(\.name) == ["Maya"])

        transport.inject(.peerUnavailable(friend))
        await eventually { model.peers.first?.isConnected == false }
        transport.inject(.peerAvailable(friend))
        await eventually { model.peers.first?.isConnected == true }
        #expect(model.peers.count == 1)
    }

    @Test func aRoundTripSendsHelloAndTimesTheReply() async throws {
        let model = model()
        await model.start()
        transport.inject(.peerAvailable(friend))
        await eventually { !model.peers.isEmpty }

        await model.ping(friend)
        let sent = try await sentEnvelopes()
        #expect(sent.count == 1)
        #expect(sent.first?.body == .hello(card), "only the agent card, never owner data")
        #expect(model.peers.first?.isWaiting == true)

        try inject(.hello(card), conversation: sent[0].conversation)
        await eventually { model.peers.first?.lastRoundTrip != nil }
        #expect(model.peers.first?.lastRoundTrip != nil)
        #expect(model.peers.first?.isWaiting == false)
    }

    @Test func answersAFriendsPingOnceInTheSameConversation() async throws {
        let model = model()
        await model.start()
        let conversation = ConversationID()
        try inject(.hello(card), conversation: conversation)
        for _ in 0..<2000 where await transport.sent.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        try inject(.hello(card), conversation: conversation, sequence: 1)
        try await Task.sleep(for: .milliseconds(50))

        let sent = try await sentEnvelopes()
        #expect(sent.count == 1)
        #expect(sent.first?.conversation == conversation)
        #expect(sent.first?.recipient == friend)
        #expect(sent.first?.body == .hello(card))
    }

    @Test func ignoresEverythingButHello() async throws {
        let model = model()
        await model.start()
        try inject(.propose(try Proposal(round: 0, terms: .empty)), conversation: ConversationID())
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await sentEnvelopes().isEmpty)
    }

    @Test func aFailedPingIsReportedAndNotLeftWaiting() async {
        let model = model()
        await model.start()
        transport.inject(.peerAvailable(friend))
        await eventually { !model.peers.isEmpty }
        await transport.failSends(with: .peerUnreachable(friend))

        await model.ping(friend)
        #expect(model.peers.first?.isWaiting == false)
        #expect(model.peers.first?.lastError != nil)
    }

    @Test func stopStopsTheTransport() async {
        let model = model()
        await model.start()
        await model.stop()
        #expect(model.status == .idle)
        #expect(await transport.isStarted == false)
    }
}
