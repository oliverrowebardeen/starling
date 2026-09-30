import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

@MainActor
@Suite struct ConsentCoordinatorTests {
    static func disclosure(to peer: PeerID, model: ModelLocality? = .onDevice) throws -> Disclosure {
        Disclosure(recipient: peer, recipientModel: model, items: [
            DisclosedItem(category: .terms, issue: .budget, value: .amount(try MoneyAmount(minorUnits: 1500))),
            DisclosedItem(category: .psi, issue: .time, value: nil),
        ])
    }

    @Test func showsWhatWillLeaveThePhoneAndReturnsTheAnswer() async throws {
        let maya = Fixtures.peer("Maya")
        let coordinator = ConsentCoordinator(peers: InMemoryPairedPeerStore([maya]), formatter: ValueFormatter(timeZone: Fixtures.utc, locale: Locale(identifier: "en_US")))
        let answer = Task { await coordinator.requestConsent(for: try! Self.disclosure(to: maya.id)) }

        await eventually { coordinator.current != nil }
        let request = try #require(coordinator.current)
        #expect(request.recipientName == "Maya")
        #expect(request.recipientModel == "Says its model runs on their iPhone")
        #expect(request.items == [
            DisplayLine(title: "Budget", detail: "$15.00"),
            DisplayLine(title: "Matching step over your free times", detail: nil),
        ])

        coordinator.answer(.approved)
        #expect(await answer.value == .approved)
        #expect(coordinator.current == nil)
    }

    @Test func dismissingTheSheetDeclines() async throws {
        let coordinator = ConsentCoordinator(peers: nil)
        let answer = Task { await coordinator.requestConsent(for: try! Self.disclosure(to: .random())) }
        await eventually { coordinator.current != nil }
        #expect(coordinator.current?.recipientName == "Someone you haven't paired with")
        coordinator.dismissed(try #require(coordinator.current).id)
        #expect(await answer.value == .declined)
    }

    @Test func queuedRequestsAreShownOneAtATimeInOrder() async throws {
        let a = Fixtures.peer("A")
        let b = Fixtures.peer("B")
        let coordinator = ConsentCoordinator(peers: InMemoryPairedPeerStore([a, b]))
        let first = Task { await coordinator.requestConsent(for: try! Self.disclosure(to: a.id)) }
        await eventually { coordinator.current != nil }
        let second = Task { await coordinator.requestConsent(for: try! Self.disclosure(to: b.id)) }
        try await Task.sleep(for: .milliseconds(20))

        #expect(coordinator.current?.recipientName == "A")
        coordinator.answer(.declined)
        #expect(await first.value == .declined)

        await eventually { coordinator.current?.recipientName == "B" }
        coordinator.answer(.approved)
        #expect(await second.value == .approved)
    }

    @Test func cancellingTheRequestDeclines() async throws {
        let coordinator = ConsentCoordinator(peers: nil)
        let answer = Task { await coordinator.requestConsent(for: try! Self.disclosure(to: .random())) }
        await eventually { coordinator.current != nil }
        answer.cancel()
        #expect(await answer.value == .declined)
        await eventually { coordinator.current == nil }
        #expect(coordinator.current == nil)
    }

    @Test func noAnswerBeforeTheTimeoutDeclines() async throws {
        let coordinator = ConsentCoordinator(peers: nil, timeout: .milliseconds(50))
        let outcome = await coordinator.requestConsent(for: try Self.disclosure(to: .random()))
        #expect(outcome == .declined)
        #expect(coordinator.current == nil)
    }

    @Test func worksAsTheOutboxConsentProvider() async throws {
        let maya = Fixtures.peer("Maya")
        let coordinator = ConsentCoordinator(peers: InMemoryPairedPeerStore([maya]))
        let transport = RecordingTransport()
        let disclosure = try Self.disclosure(to: maya.id)
        let outbox = Outbox(transport: transport, policy: FixedPolicyEngine(.needsConsent(disclosure)), consent: coordinator)
        let body = MessageBody.propose(try Proposal(round: 0, terms: .empty))

        let send = Task { try await outbox.send(body, to: maya.id, conversation: ConversationID()) }
        await eventually { coordinator.current != nil }
        coordinator.answer(.declined)
        await #expect(throws: OutboxError.consentDeclined) { try await send.value }
        #expect(await transport.sent.isEmpty)
    }
}
