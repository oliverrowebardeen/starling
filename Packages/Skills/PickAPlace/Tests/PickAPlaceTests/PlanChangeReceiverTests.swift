import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingTransport
import Testing

/// A friend's checks on what an organizer sends (review of #118, finding 3).
/// Mallory organizes by hand, so her messages can be anything.
@Suite("A friend's checks on a place change", .serialized)
struct PlanChangeReceiverTests {
    func mallorysGroup() async throws -> (Group, mallory: Phone, maya: Phone, jake: Phone) {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let mallory = Phone("Mallory", hub: hub, maps: maps)
        let maya = Phone("Maya", hub: hub, maps: maps)
        let jake = Phone("Jake", hub: hub, maps: maps)
        return (try await Group([mallory, maya, jake], hub: hub), mallory, maya, jake)
    }

    @discardableResult
    func send(_ body: MessageBody, from sender: Phone, to recipient: Phone, in conversation: ConversationID,
              chainedFrom: ConversationID?) async throws -> Envelope {
        try await sender.outbox.send(body, to: recipient.id, conversation: conversation, skill: PickAPlaceSkill.ref, mode: .invite,
                                     chainedFrom: chainedFrom)
    }

    func terms(_ roster: [Phone]) throws -> Terms {
        try Terms([.place: .places([Venues.bobaGuys.choice]), .people: .peers(roster.map(\.id)), .activity: .keywords([kw("boba")])])
    }

    /// Mallory asks Maya about Boba Guys, and waits for Maya's list.
    func ask(_ maya: Phone, from mallory: Phone, in conversation: ConversationID, chainedFrom: ConversationID?, _ group: Group) async throws {
        try await send(.query(Query(issue: .place, candidates: .places([Venues.bobaGuys.choice]))), from: mallory, to: maya,
                       in: conversation, chainedFrom: chainedFrom)
        #expect(await eventually { await group.wire.sent(by: maya.id).contains { $0.conversation == conversation && $0.body.kind == .answer } })
    }

    /// Whether `phone` has said yes naming the proposal sent as `offer`.
    func saidYes(by phone: Phone, to offer: Envelope, _ group: Group) async -> Bool {
        await group.wire.sent(by: phone.id).contains {
            if case .accept(let acceptance) = $0.body { acceptance.proposal == offer.id } else { false }
        }
    }

    /// Finding 3: the same terms at another revision are a new proposal.
    /// Maya's yes to the first is not repeated for the second, which needs
    /// her to decide again; and after a restart, a retry of the proposal
    /// she said yes to is still recognized as one.
    @Test func aNewRevisionNeedsAFreshYes() async throws {
        let (group, mallory, maya, _) = try await mallorysGroup()
        defer { Task { await group.stop() } }
        let conversation = ConversationID()
        try await ask(maya, from: mallory, in: conversation, chainedFrom: nil, group)
        let roster = try terms([mallory, maya])

        let first = try await send(.propose(Proposal(round: 0, terms: roster)), from: mallory, to: maya, in: conversation, chainedFrom: nil)
        #expect(await maya.reaches(.proposed, in: conversation))
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))
        #expect(await eventually { await saidYes(by: maya, to: first, group) })

        // A retry: Maya says yes to it again.
        let retry = try await send(.propose(Proposal(round: 0, terms: roster)), from: mallory, to: maya, in: conversation, chainedFrom: nil)
        #expect(await eventually { await saidYes(by: maya, to: retry, group) })

        // The same terms at a new revision: a new card, and no yes to it
        // until Maya taps.
        let newer = try await send(.propose(Proposal(round: 1, terms: roster)), from: mallory, to: maya, in: conversation, chainedFrom: nil)
        #expect(await maya.reaches(.proposed, in: conversation))
        #expect(await maya.interaction(conversation)?.proposalRevision == 2)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await !saidYes(by: maya, to: newer, group))

        // Maya says yes to it, and her app restarts. A retry of it is still
        // a retry: she says yes again without being asked.
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))
        #expect(await eventually { await saidYes(by: maya, to: newer, group) })
        await maya.restart()
        let again = try await send(.propose(Proposal(round: 1, terms: roster)), from: mallory, to: maya, in: conversation, chainedFrom: nil)
        #expect(await eventually { await saidYes(by: maya, to: again, group) })
        #expect(await maya.state(in: conversation) == .confirmed)
        #expect(await group.lifecyclesWereLegal())
    }
}
