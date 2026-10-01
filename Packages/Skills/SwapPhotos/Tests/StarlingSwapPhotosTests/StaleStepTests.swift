import Foundation
import StarlingCore
import StarlingFakes
import StarlingSwapPhotos
import Testing

/// Holds each evaluation at the gate, then gives `decision`.
actor GatedPolicy: PolicyEngine {
    let gate = Gate()
    let decision: PolicyDecision

    init(_ decision: PolicyDecision) { self.decision = decision }

    func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        await gate.pass()
        return decision
    }
}

/// ADR 0011 amendment 14: a service reports a denial or failure only for a
/// send made for the interaction's current step. Each test plays the
/// coordinator, applying every event the service reports to a real
/// `Interaction`, so an event Core would reject fails the test.
@Suite struct StaleStepTests {
    static let photosNever = PolicyViolation(rule: "disclosure.never", issue: .photos)

    struct Friend {
        let phone: Phone
        let conversation = ConversationID()
        var interaction: Interaction?
        var iterator: AsyncStream<SkillEvent>.Iterator

        init(_ phone: Phone) {
            self.phone = phone
            iterator = phone.service.events.makeAsyncIterator()
        }

        /// Applies the next `count` events as the coordinator would.
        mutating func coordinate(_ count: Int) async throws -> [SkillEvent] {
            var seen: [SkillEvent] = []
            while seen.count < count, let event = await iterator.next() {
                seen.append(event)
                switch event {
                case .incoming(let id, let conversation, let from, _):
                    interaction = Interaction(id: id, conversation: conversation, skill: SwapPhotos.descriptor.ref, role: .invitee,
                                              participants: [from], createdAt: Fixtures.at(minutes: 211))
                case .lifecycle(_, let lifecycle):
                    try interaction?.apply(lifecycle, at: Fixtures.at(minutes: 212))
                case .produced:
                    break
                }
            }
            return seen
        }

        func offer(_ count: Int) throws -> Envelope { try Fixtures.offer(count: count, conversation: conversation) }
    }

    @Test func aDeniedAcceptanceEndsTheInviteeBlockedByPrivacy() async throws {
        var friend = Friend(Phone(policy: .deny(Self.photosNever)))
        await friend.phone.service.handle(.message(try friend.offer(5)))
        _ = try await friend.coordinate(2)
        let id = try #require(friend.interaction?.id)
        try await friend.phone.service.answer(id, with: .accept(proposal: 1))
        #expect(try await friend.coordinate(1) == [.lifecycle(id, .blockedByPrivacy)])
        #expect(friend.interaction?.state == .ended(.blockedByPrivacy))
        #expect(await friend.phone.transport.sent.isEmpty)
    }

    @Test func aDenialForAReplacedCardIsDropped() async throws {
        let policy = GatedPolicy(.deny(Self.photosNever))
        var friend = Friend(Phone(policy: policy, consent: ScriptedConsentProvider(.approved)))
        await friend.phone.service.handle(.message(try friend.offer(5)))
        _ = try await friend.coordinate(2)
        let id = try #require(friend.interaction?.id)

        // The owner accepts card 1; the policy is still deciding when the
        // friend's newer offer replaces the card.
        let service = friend.phone.service
        let accepting = Task { try await service.answer(id, with: .accept(proposal: 1)) }
        await policy.gate.arrived()
        await friend.phone.service.handle(.message(try friend.offer(2)))
        #expect(try await friend.coordinate(1) == [.lifecycle(id, .proposalReady(SkillProposal(
            revision: 2, participants: [Fixtures.maya, Fixtures.me], terms: try Terms([.photos: .count(2)]))))])
        await policy.gate.open()
        _ = await accepting.result

        // Card 1's denial is not reported: card 2 is still waiting.
        #expect(friend.interaction?.state == .proposed)
        #expect(friend.interaction?.proposalRevision == 2)
        // A denial for the current card is.
        try await friend.phone.service.answer(id, with: .accept(proposal: 2))
        #expect(try await friend.coordinate(1) == [.lifecycle(id, .blockedByPrivacy)])
        #expect(friend.interaction?.state == .ended(.blockedByPrivacy))
    }

    @Test func anAcceptanceThatLandsAfterTheCardWasReplacedReportsNothing() async throws {
        let policy = GatedPolicy(.allow)
        var friend = Friend(Phone(policy: policy, consent: ScriptedConsentProvider(.approved)))
        await friend.phone.service.handle(.message(try friend.offer(5)))
        _ = try await friend.coordinate(2)
        let id = try #require(friend.interaction?.id)

        let service = friend.phone.service
        let accepting = Task { try await service.answer(id, with: .accept(proposal: 1)) }
        await policy.gate.arrived()
        await friend.phone.service.handle(.message(try friend.offer(2)))
        _ = try await friend.coordinate(1)
        await policy.gate.open()
        _ = await accepting.result

        // The owner did say yes to card 1, so it went out; but no
        // ownerAccepted(1) follows, which would be stale against card 2.
        #expect(await friend.phone.transport.sent.count == 1)
        try await friend.phone.service.answer(id, with: .accept(proposal: 2))
        #expect(try await friend.coordinate(1) == [.lifecycle(id, .ownerAccepted(revision: 2))])
        #expect(friend.interaction?.state == .confirmed)
    }
}
