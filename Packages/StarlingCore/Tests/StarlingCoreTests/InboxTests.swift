import Foundation
import StarlingCore
import StarlingFakes
import Testing

@Suite struct InboxTests {
    let codec = EnvelopeCodec()

    func inbox(at now: Date = Fixtures.now) -> Inbox {
        Inbox(localPeer: Fixtures.bob, now: { now })
    }

    func frame(_ envelope: Envelope) throws -> Frame { try Frame(codec.encode(envelope)) }

    @Test func acceptsAValidEnvelope() async throws {
        let envelope = try Fixtures.proposalEnvelope()
        #expect(await inbox().accept(try frame(envelope), from: Fixtures.alice) == .success(envelope))
    }

    @Test func dropsMessagesForSomeoneElse() async throws {
        let envelope = try Fixtures.proposalEnvelope(to: Fixtures.mallory)
        #expect(await inbox().accept(try frame(envelope), from: Fixtures.alice) == .failure(.wrongRecipient))
    }

    @Test func dropsSpoofedSenders() async throws {
        let envelope = try Fixtures.proposalEnvelope(from: Fixtures.alice)
        #expect(await inbox().accept(try frame(envelope), from: Fixtures.mallory) == .failure(.senderMismatch))
    }

    @Test func dropsExactReplays() async throws {
        let inbox = inbox()
        let replayed = try frame(Fixtures.proposalEnvelope(sequence: 5))
        #expect(await inbox.accept(replayed, from: Fixtures.alice).isSuccess)
        #expect(await inbox.accept(replayed, from: Fixtures.alice) == .failure(.replay))
    }

    @Test func dropsReusedSequenceNumbersEvenWithNewIDs() async throws {
        let inbox = inbox()
        #expect(await inbox.accept(try frame(Fixtures.proposalEnvelope(sequence: 5)), from: Fixtures.alice).isSuccess)
        let forged = try Fixtures.proposalEnvelope(sequence: 5, id: MessageID())
        #expect(await inbox.accept(try frame(forged), from: Fixtures.alice) == .failure(.replay))
    }

    @Test func toleratesReorderingInsideTheWindow() async throws {
        let inbox = inbox()
        for sequence: UInt64 in [3, 1, 2, 0] {
            #expect(await inbox.accept(try frame(Fixtures.proposalEnvelope(sequence: sequence)), from: Fixtures.alice).isSuccess)
        }
    }

    @Test func dropsSequencesBelowTheWindow() async throws {
        let inbox = inbox()
        #expect(await inbox.accept(try frame(Fixtures.proposalEnvelope(sequence: 100)), from: Fixtures.alice).isSuccess)
        let old = try Fixtures.proposalEnvelope(sequence: 100 - Inbox.replayWindow)
        #expect(await inbox.accept(try frame(old), from: Fixtures.alice) == .failure(.replay))
    }

    @Test func dropsStaleAndFutureMessages() async throws {
        let stale = try Fixtures.proposalEnvelope(sentAt: Fixtures.now.addingTimeInterval(-601))
        let future = try Fixtures.proposalEnvelope(sentAt: Fixtures.now.addingTimeInterval(121))
        #expect(await inbox().accept(try frame(stale), from: Fixtures.alice) == .failure(.stale))
        #expect(await inbox().accept(try frame(future), from: Fixtures.alice) == .failure(.fromFuture))
    }

    @Test func dropsGarbage() async throws {
        let result = await inbox().accept(try Frame(Data("garbage".utf8)), from: Fixtures.alice)
        guard case .failure(.codec(.malformed)) = result else {
            Issue.record("expected a malformed codec error, got \(result)")
            return
        }
    }

    @Test func mapsTransportEventsIntoInboxEvents() async throws {
        let transport = RecordingTransport(localPeer: Fixtures.bob)
        let events = inbox().events(from: transport)
        let envelope = try Fixtures.proposalEnvelope()

        transport.inject(.peerAvailable(Fixtures.alice))
        transport.inject(.received(try frame(envelope), from: Fixtures.alice))
        transport.inject(.received(try frame(envelope), from: Fixtures.alice))
        await transport.stop()

        var collected: [InboxEvent] = []
        for await event in events { collected.append(event) }
        #expect(collected == [
            .peerAvailable(Fixtures.alice),
            .message(envelope),
            .dropped(from: Fixtures.alice, reason: .replay),
        ])
    }
}

extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}
