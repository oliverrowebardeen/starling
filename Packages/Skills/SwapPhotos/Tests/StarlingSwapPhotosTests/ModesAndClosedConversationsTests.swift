import Foundation
import StarlingCore
import StarlingFakes
import StarlingSwapPhotos
import Testing

/// A ledger whose retirements a test can hold at a gate or refuse.
actor GatedLedger: ConversationLedger {
    struct Refused: Error {}
    let gate = Gate()
    private let inner = InMemoryConversationLedger()
    private var holding = false
    private var refusing = false

    func holdRetirements() { holding = true }
    func refuseRetirements(_ value: Bool) { refusing = value }

    func isRetired(_ conversation: ConversationID) async throws -> Bool { try await inner.isRetired(conversation) }
    func retire(_ conversation: ConversationID) async throws {
        if holding { await gate.pass() }
        if refusing { throw Refused() }
        try await inner.retire(conversation)
    }
    func reserve(_ candidates: [IssueValue], issue: IssueKey, to peer: PeerID, in conversation: ConversationID) async throws -> Bool {
        try await inner.reserve(candidates, issue: issue, to: peer, in: conversation)
    }
}

/// Core v2.1: send modes (ADR 0020), the interaction on every send, and
/// conversations that stay closed after they end (ADR 0011 amendment 15).
@Suite struct ModesAndClosedConversationsTests {
    static func incomingIDs(_ events: [SkillEvent]) -> [InteractionID] {
        events.compactMap { if case .incoming(let id, _, _, _) = $0 { id } else { nil } }
    }

    @Test func everySendInvitesAndNamesItsInteraction() async throws {
        let policy = FixedPolicyEngine(.allow)
        let phone = Phone(policy: policy, consent: ScriptedConsentProvider(.approved))
        let request = Fixtures.request()
        try await phone.service.start(request)
        try await phone.service.answer(request.interaction, with: .reply(question: 1, .count(2)))
        let offers = await policy.evaluated
        #expect(offers.count == 2)
        #expect(offers.allSatisfy { $0.envelope.mode == .invite && $0.context.interaction == request.interaction })

        // A friend's acceptance names the friend's own interaction.
        let friendPolicy = FixedPolicyEngine(.allow)
        let friend = Phone(policy: friendPolicy, consent: ScriptedConsentProvider(.approved))
        await friend.service.handle(.message(try Fixtures.offer()))
        var iterator = friend.service.events.makeAsyncIterator()
        guard case .incoming(let id, _, _, _) = await iterator.next() else {
            Issue.record("expected an incoming interaction")
            return
        }
        try await friend.service.answer(id, with: .accept(proposal: 1))
        let acceptance = try #require(await friendPolicy.evaluated.first)
        #expect(acceptance.envelope.mode == .invite)
        #expect(acceptance.context.interaction == id)
        // The acceptance names the offer it accepts, exactly as offered.
        let offered = try Proposal(round: 0, terms: Terms([.photos: .count(5)]))
        #expect(acceptance.context.accepting == offered)
        guard case .accept(let accepted) = acceptance.envelope.body else {
            Issue.record("expected an acceptance")
            return
        }
        #expect(offered.isAcceptedAsOffered(by: accepted))
        // The owner's own offers accept nothing.
        #expect(offers.allSatisfy { $0.context.accepting == nil })
    }

    @Test func swapPhotosOnlyInvites() async throws {
        #expect(SwapPhotos.descriptor.sendModes == [.invite])
        let phone = Phone()
        await #expect(throws: SwapPhotosError.wrongSkill) { try await phone.service.start(Fixtures.request(mode: .askQuietly)) }
        // A quiet ask is ignored like an unknown request: never a card.
        await phone.service.handle(.message(try Fixtures.offer(mode: .askQuietly)))
        #expect(await phone.events().isEmpty)
    }

    @Test func aRetriedOfferAfterAPassDoesNotShowTheCardAgain() async throws {
        let phone = Phone()
        let offer = try Fixtures.offer()
        await phone.service.handle(.message(offer))
        var iterator = phone.service.events.makeAsyncIterator()
        guard case .incoming(let id, _, _, _) = await iterator.next() else {
            Issue.record("expected an incoming interaction")
            return
        }
        try await phone.service.answer(id, with: .pass)
        // The friend's agent retries the same offer, and then a new one, in that conversation.
        await phone.service.handle(.message(offer))
        await phone.service.handle(.message(try Fixtures.offer(count: 3, conversation: offer.conversation)))
        #expect(Self.incomingIDs(await phone.events()).isEmpty)
    }

    @Test func aConversationThatEndedBeforeARestartStaysClosed() async throws {
        let phone = Phone()
        let conversation = ConversationID()
        var ended = Interaction(conversation: conversation, skill: SwapPhotos.descriptor.ref, role: .invitee, participants: [Fixtures.maya],
                                createdAt: Fixtures.at(minutes: 211))
        try ended.apply(.expired, at: Fixtures.at(minutes: 212))
        #expect(ended.state.isFinal)
        await phone.service.restore([ended])
        await phone.service.handle(.message(try Fixtures.offer(conversation: conversation)))
        #expect(await phone.events().isEmpty)
    }

    @Test func everyEndingRetiresTheConversationThroughOutbox() async throws {
        // A friend's card the owner passes on.
        let phone = Phone()
        let offer = try Fixtures.offer()
        await phone.service.handle(.message(offer))
        var iterator = phone.service.events.makeAsyncIterator()
        guard case .incoming(let id, _, _, _) = await iterator.next() else {
            Issue.record("expected an incoming interaction")
            return
        }
        try await phone.service.answer(id, with: .pass)
        #expect(try await phone.ledger.isRetired(offer.conversation))

        // The owner's own Swap photos, withdrawn while picking.
        let request = Fixtures.request()
        try await phone.service.start(request)
        await phone.service.withdraw(request.interaction)
        #expect(try await phone.ledger.isRetired(request.conversation))
        #expect(await phone.service.retireFailures == 0)
    }

    @Test func aConversationTheLedgerRetiredIsNeverOpened() async throws {
        // Retired on an earlier launch, past any 24-hour restore window.
        let ledger = InMemoryConversationLedger()
        let conversation = ConversationID()
        try await ledger.retire(conversation)
        let phone = Phone(ledger: ledger)
        await phone.service.handle(.message(try Fixtures.offer(conversation: conversation)))
        #expect(await phone.events().isEmpty)
    }

    @Test func aLedgerThatCannotAnswerOpensNothing() async throws {
        let ledger = InMemoryConversationLedger()
        await ledger.failAll()
        let phone = Phone(ledger: ledger)
        await phone.service.handle(.message(try Fixtures.offer()))
        #expect(await phone.events().isEmpty)
    }

    static func openCard(_ phone: Phone) async throws -> (InteractionID, ConversationID, AsyncStream<SkillEvent>.Iterator) {
        let offer = try Fixtures.offer()
        await phone.service.handle(.message(offer))
        var iterator = phone.service.events.makeAsyncIterator()
        guard case .incoming(let id, _, _, _) = await iterator.next() else { throw SwapPhotosError.unknownInteraction(InteractionID()) }
        _ = await iterator.next()  // the proposal card
        return (id, offer.conversation, iterator)
    }

    @Test func aPassIsReportedOnlyOnceTheRetirementIsDurable() async throws {
        let ledger = GatedLedger()
        let phone = Phone(ledger: ledger)
        let (id, conversation, _) = try await Self.openCard(phone)
        await ledger.holdRetirements()
        let service = phone.service
        let passing = Task { try await service.answer(id, with: .pass) }
        await ledger.gate.arrived()
        // The retirement is still being written: no ending reported yet, so a
        // crash now leaves the card live and restore retires it, never a
        // reported pass with the conversation still open.
        #expect(try await !ledger.isRetired(conversation))
        let early = await phone.events()
        #expect(!early.contains(.lifecycle(id, .ownerPassed)))
        await ledger.gate.open()
        _ = await passing.result
        #expect(try await ledger.isRetired(conversation))
    }

    @Test func aRetirementTheLedgerRefusesIsNotReportedAsCleanEnding() async throws {
        let ledger = GatedLedger()
        let phone = Phone(ledger: ledger)
        let (id, conversation, iterator) = try await Self.openCard(phone)
        var events = iterator
        await ledger.refuseRetirements(true)
        try await phone.service.answer(id, with: .pass)
        #expect(await events.next() == .lifecycle(id, .failed))
        #expect(await phone.service.unretiredConversations == [conversation])
        #expect(await phone.service.retireFailures == 1)
        // Still closed on this launch.
        await phone.service.handle(.message(try Fixtures.offer(conversation: conversation)))
        // Storage recovers: the retirement is recorded.
        await ledger.refuseRetirements(false)
        await phone.service.retryRetirements()
        #expect(await phone.service.unretiredConversations.isEmpty)
        #expect(try await ledger.isRetired(conversation))
        await phone.service.shutdown()
        var rest: [SkillEvent] = []
        while let event = await events.next() { rest.append(event) }
        #expect(rest.isEmpty)
    }
}
