import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingNegotiation
import Testing

@Suite(.timeLimit(.minutes(1))) struct DownLifecycleTests {
    func negotiator(clock: DownClock = pinnedClock, friends: [PairedPeer] = []) -> (DownNegotiator, RecordingTransport) {
        let transport = RecordingTransport()
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved))
        let negotiator = DownNegotiator(
            localPeer: transport.localPeer, outbox: outbox, pairedPeers: InMemoryPairedPeerStore(friends),
            model: ScriptedAgentModel(), psi: InsecurePSIStub(), clock: clock,
            timeZone: TimeZone(identifier: "UTC")!, configuration: fastConfiguration
        )
        return (negotiator, transport)
    }

    func intent(expiresAt: Date = T.at(24), time: [TimeSlot] = [T.slot(19, 22)]) throws -> DownIntent {
        DownIntent(rules: OwnerRules(constraints: try T.constraints(time: time)), level: .down, expiresAt: Timestamp(expiresAt))
    }

    func friend(_ name: String) throws -> PairedPeer {
        try PairedPeer(publicKey: IdentityPublicKey(bytes: Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })), nickname: name, pairedAt: Timestamp(T.now))
    }

    @Test func anIntentMustBeInTheFutureAndLeaveSomeTime() async throws {
        let (down, _) = negotiator()
        await #expect(throws: DownError.expired) { try await down.setIntent(try intent(expiresAt: T.now)) }
        await #expect(throws: DownError.noAvailableTime) { try await down.setIntent(try intent(time: [T.slot(10, 11)])) }
        await down.shutdown()
    }

    @Test func settingAnIntentChecksReachablePairedFriendsOnly() async throws {
        let (ana, ben) = (try friend("ana"), try friend("ben"))
        let (down, transport) = negotiator(friends: [ana, ben])
        await down.handle(.peerAvailable(ana.id))
        await down.handle(.peerAvailable(PeerID.random()))
        try await down.setIntent(try intent())

        var events = down.events.makeAsyncIterator()
        #expect(await events.next() == .checking(friends: 1))
        try await eventually("a PSI run with ana") { await transport.sent.contains { $0.peer == ana.id } }
        #expect(await transport.sent.allSatisfy { $0.peer == ana.id })
        await down.shutdown()
    }

    @Test func clearingTheIntentEndsQuietlyForFriends() async throws {
        let ana = try friend("ana")
        let (down, transport) = negotiator(friends: [ana])
        await down.handle(.peerAvailable(ana.id))
        try await down.setIntent(try intent())
        try await eventually("run started") { await !transport.sent.isEmpty }
        await down.clearIntent()
        let sentBefore = await transport.sent.count

        var events = down.events.makeAsyncIterator()
        #expect(await events.next() == .checking(friends: 1))
        #expect(await events.next() == .ended(.withdrawn))
        try await Task.sleep(for: .milliseconds(100))
        // No retries and no goodbye message.
        #expect(await transport.sent.count == sentBefore)
        #expect(await down.conversations.isEmpty)
        await down.shutdown()
    }

    @Test func anIntentEndsWhenItExpires() async throws {
        // Timers run 100,000 times faster: the hour below takes 36 ms.
        let fast = DownClock(now: { T.now }, sleep: { try await Task.sleep(for: $0 / 100_000) })
        let (down, _) = negotiator(clock: fast)
        try await down.setIntent(try intent(expiresAt: T.at(20)))
        var events = down.events.makeAsyncIterator()
        #expect(await events.next() == .checking(friends: 0))
        #expect(await events.next() == .ended(.expired))
        await down.shutdown()
    }

    @Test func messagesFromUnpairedPeersAreIgnored() async throws {
        let (down, transport) = negotiator()
        try await down.setIntent(try intent())
        let stranger = PeerID.random()
        let frame = try PSIFrame(session: UUID(), step: 0, payload: Data("{}".utf8))
        let envelope = try Envelope(conversation: ConversationID(), sender: stranger, recipient: transport.localPeer, sequence: 0, sentAt: Timestamp(T.now), body: .psi(frame))
        await down.handle(.message(envelope))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await down.conversations.isEmpty)
        #expect(await transport.sent.isEmpty)
        await down.shutdown()
    }
}
