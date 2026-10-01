import Foundation
import StarlingCore
import StarlingFakes
import StarlingSwapPhotos
import Testing

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
}
