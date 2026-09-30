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

/// A clock tests can move.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Fixtures.noon) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

@MainActor
@Suite struct ConsentMemoryTests {
    let maya = Fixtures.peer("Maya")
    let clock = TestClock()

    func coordinator(timeout: Duration = .seconds(120)) -> ConsentCoordinator {
        let clock = clock
        return ConsentCoordinator(peers: InMemoryPairedPeerStore([maya]), timeout: timeout, now: { clock.now })
    }

    /// Requests consent and answers it from the sheet if one appears.
    /// Returns the outcome and whether a sheet was shown.
    func ask(_ coordinator: ConsentCoordinator, _ disclosure: Disclosure, answer: ConsentOutcome) async -> (ConsentOutcome, shown: Bool) {
        let request = Task { await coordinator.requestConsent(for: disclosure) }
        for _ in 0..<50 where coordinator.current == nil { try? await Task.sleep(for: .milliseconds(1)) }
        let shown = coordinator.current != nil
        if shown { coordinator.answer(answer) }
        return (await request.value, shown)
    }

    @Test func anApprovedDisclosureIsNotAskedAgainWithinTenMinutes() async throws {
        let consent = coordinator()
        let disclosure = try ConsentCoordinatorTests.disclosure(to: maya.id)
        #expect(await ask(consent, disclosure, answer: .approved) == (.approved, true))
        clock.advance(9 * 60)
        #expect(await ask(consent, disclosure, answer: .declined) == (.approved, false))
    }

    @Test func approvalExpiresAfterTenMinutes() async throws {
        let consent = coordinator()
        let disclosure = try ConsentCoordinatorTests.disclosure(to: maya.id)
        _ = await ask(consent, disclosure, answer: .approved)
        clock.advance(10 * 60)
        #expect(await ask(consent, disclosure, answer: .declined) == (.declined, true))
    }

    @Test func aDifferentDisclosureIsAskedAgain() async throws {
        let consent = coordinator()
        _ = await ask(consent, try ConsentCoordinatorTests.disclosure(to: maya.id), answer: .approved)

        let otherItems = Disclosure(recipient: maya.id, recipientModel: .onDevice, items: [
            DisclosedItem(category: .terms, issue: .budget, value: .amount(try MoneyAmount(minorUnits: 2000))),
        ])
        let otherModel = try ConsentCoordinatorTests.disclosure(to: maya.id, model: .thirdPartyCloud(provider: "acme"))
        let otherPeer = try ConsentCoordinatorTests.disclosure(to: .random())
        for disclosure in [otherItems, otherModel, otherPeer] {
            #expect(await ask(consent, disclosure, answer: .declined) == (.declined, true))
        }
    }

    @Test func aDeclineIsNeverRemembered() async throws {
        let consent = coordinator()
        let disclosure = try ConsentCoordinatorTests.disclosure(to: maya.id)
        #expect(await ask(consent, disclosure, answer: .declined) == (.declined, true))
        #expect(await ask(consent, disclosure, answer: .approved) == (.approved, true))
    }

    @Test func aTimeoutIsNeverRemembered() async throws {
        let consent = coordinator(timeout: .milliseconds(20))
        let disclosure = try ConsentCoordinatorTests.disclosure(to: maya.id)
        #expect(await consent.requestConsent(for: disclosure) == .declined)
        let second = Task { await consent.requestConsent(for: disclosure) }
        await eventually { consent.current != nil }
        #expect(consent.current != nil)
        _ = await second.value
    }

    @Test func forgettingApprovalsAsksAgain() async throws {
        let consent = coordinator()
        let disclosure = try ConsentCoordinatorTests.disclosure(to: maya.id)
        _ = await ask(consent, disclosure, answer: .approved)
        consent.forgetApprovals()
        #expect(await ask(consent, disclosure, answer: .declined) == (.declined, true))
    }

    @Test func oneAnswerCoversIdenticalRequestsAlreadyWaiting() async throws {
        let consent = coordinator()
        let disclosure = try ConsentCoordinatorTests.disclosure(to: maya.id)
        let other = try ConsentCoordinatorTests.disclosure(to: .random())
        let first = Task { await consent.requestConsent(for: disclosure) }
        await eventually { consent.current != nil }
        let retry = Task { await consent.requestConsent(for: disclosure) }
        let unrelated = Task { await consent.requestConsent(for: other) }
        try await Task.sleep(for: .milliseconds(20))

        consent.answer(.declined)
        #expect(await first.value == .declined)
        #expect(await retry.value == .declined)
        await eventually { consent.current?.disclosure == other }
        #expect(consent.current?.disclosure == other, "an unrelated request still gets its own sheet")
        consent.answer(.approved)
        #expect(await unrelated.value == .approved)
    }
}
