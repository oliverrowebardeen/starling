import Foundation
import StarlingCore
import StarlingFakes
import StarlingSwapPhotos
import Testing

/// Core v2.1: send modes (ADR 0020) and the interaction on every send.
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
    }

    @Test func swapPhotosOnlyInvites() async throws {
        #expect(SwapPhotos.descriptor.sendModes == [.invite])
        let phone = Phone()
        await #expect(throws: SwapPhotosError.wrongSkill) { try await phone.service.start(Fixtures.request(mode: .askQuietly)) }
        // A quiet ask is ignored like an unknown request: never a card.
        await phone.service.handle(.message(try Fixtures.offer(mode: .askQuietly)))
        #expect(await phone.events().isEmpty)
    }
}
