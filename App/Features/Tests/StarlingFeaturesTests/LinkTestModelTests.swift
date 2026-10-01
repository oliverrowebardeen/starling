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

    func model(replyTimeout: Duration = .seconds(10)) -> LinkTestModel {
        let friend = friend
        return LinkTestModel(
            outbox: Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.declined)),
            card: card,
            name: { $0 == friend ? "Maya" : nil },
            replyTimeout: replyTimeout
        )
    }

    func sentEnvelopes() async throws -> [Envelope] {
        try await transport.sent.map { try EnvelopeCodec().decode($0.frame.bytes) }
    }

    func waitForSends(_ count: Int) async throws {
        for _ in 0..<2000 where await transport.sent.count < count { try await Task.sleep(for: .milliseconds(1)) }
    }

    func hello(conversation: ConversationID, sequence: UInt64 = 0) throws -> InboxEvent {
        .message(try Envelope(conversation: conversation, sender: friend, recipient: transport.localPeer,
                              sequence: sequence, sentAt: Timestamp(Date()), body: .hello(card)))
    }

    @Test func greetsAPeerThatBecomesAvailableAndTimesTheReply() async throws {
        let model = model()
        await model.handle(.peerAvailable(friend))
        #expect(model.peers.map(\.name) == ["Maya"])
        #expect(model.peers.first?.isConnected == true)

        try await waitForSends(1)
        let greeting = try #require(try await sentEnvelopes().first)
        #expect(greeting.body == .hello(card), "the agent card only, never owner data")
        #expect(greeting.recipient == friend)

        await model.handle(try hello(conversation: greeting.conversation))
        #expect(model.peers.first?.lastRoundTrip != nil)
        #expect(model.peers.first?.isWaiting == false)
        try await Task.sleep(for: .milliseconds(20))
        #expect(try await sentEnvelopes().count == 1, "a reply to our own hello is not answered")
    }

    @Test func showsEachPeerOnceWithItsConnectionState() async {
        let model = model()
        await model.handle(.peerAvailable(friend))
        await model.handle(.peerUnavailable(friend))
        #expect(model.peers.first?.isConnected == false)
        await model.handle(.peerAvailable(friend))
        #expect(model.peers.count == 1)
        #expect(model.peers.first?.isConnected == true)
    }

    @Test func answersAFriendsHelloOnceInTheSameConversation() async throws {
        let model = model()
        let conversation = ConversationID()
        await model.handle(try hello(conversation: conversation))
        await model.handle(try hello(conversation: conversation, sequence: 1))
        try await waitForSends(1)
        try await Task.sleep(for: .milliseconds(20))

        let sent = try await sentEnvelopes()
        #expect(sent.count == 1)
        #expect(sent.first?.conversation == conversation)
        #expect(sent.first?.body == .hello(card))
    }

    @Test func ignoresEverythingButHello() async throws {
        let model = model()
        await model.handle(.message(try Envelope(conversation: ConversationID(), sender: friend, recipient: transport.localPeer,
                                                  sequence: 0, sentAt: Timestamp(Date()), body: .propose(try Proposal(round: 0, terms: .empty)))))
        try await Task.sleep(for: .milliseconds(20))
        #expect(try await sentEnvelopes().isEmpty)
    }

    @Test func aFailedPingIsReportedAndNotLeftWaiting() async {
        let model = model()
        await transport.failSends(with: .peerUnreachable(friend))
        await model.ping(friend)
        #expect(model.peers.first?.isWaiting == false)
        #expect(model.peers.first?.lastError != nil)
    }

    /// Review finding 3 on PR #27: a round trip with no reply must not
    /// leave the button disabled for good.
    @Test func aRoundTripWithNoReplyTimesOutAndCanBeRetried() async throws {
        let model = model(replyTimeout: .milliseconds(50))
        await model.ping(friend)
        #expect(model.peers.first?.isWaiting == true)
        await eventually { model.peers.first?.isWaiting == false }
        #expect(model.peers.first?.lastError?.contains("No reply") == true)

        // A late reply to the timed-out ping is not counted as a round trip.
        let late = try await sentEnvelopes()[0].conversation
        await model.handle(try hello(conversation: late))
        #expect(model.peers.first?.lastRoundTrip == nil)

        await model.ping(friend)
        #expect(model.peers.first?.isWaiting == true, "retry works")
    }
}
