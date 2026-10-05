import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingTransport
import Testing

/// Issue #105 (lane F): Outbox returns a sent envelope only after its
/// observer has run, so a fast friend's reply can arrive before the
/// organizer has recorded what it sent. Such a reply is held until that
/// send returns, and still counts only if it names what was sent to that
/// friend in that conversation (issue #63).
@Suite("Replies that arrive before their send returns", .serialized)
struct EarlyReplyTests {
    let skill = PickAPlaceSkill.ref

    func threeFriends() async throws -> (Group, oliver: Phone, maya: Phone, jake: Phone) {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let maya = Phone("Maya", hub: hub, maps: maps)
        let jake = Phone("Jake", hub: hub, maps: maps)
        return (try await Group([oliver, maya, jake], hub: hub), oliver, maya, jake)
    }

    @Test func answersThatArriveBeforeTheirQuerySendReturnsCount() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await oliver.hold.release(); await group.stop() } }
        await oliver.hold.hold([.query])
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation

        // Both friends answer while Oliver's sends are still returning.
        for friend in [maya, jake] {
            #expect(await eventually { await group.wire.sent(by: friend.id).contains { $0.body.kind == .answer } }, "\(friend.name)")
        }
        #expect(await eventually { await oliver.service.organized[conversation]?.early.count == 2 })
        let before = try #require(await oliver.service.organized[conversation])
        #expect(before.queryIDs.isEmpty && before.answers.isEmpty)

        // Retries stay held, so only the held answers can move this on.
        await oliver.hold.release(holdingOn: true)
        #expect(await eventually { await oliver.service.organized[conversation]?.answers.count == 2 })
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }
        #expect(await oliver.service.organized[conversation]?.early.isEmpty == true)
        #expect(await group.lifecyclesWereLegal())
    }

    /// The same ordering for a proposal: a yes can arrive before the send
    /// of the proposal it names returns.
    @Test func aYesThatArrivesBeforeItsProposalSendReturnsCounts() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await oliver.hold.release(); await group.stop() } }
        await oliver.hold.hold([.propose])
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }
        try await maya.accept(in: conversation)
        try await jake.accept(in: conversation)
        #expect(await eventually { await oliver.service.organized[conversation]?.early.count == 2 })
        #expect(await oliver.service.organized[conversation]?.accepted.isEmpty == true)

        await oliver.hold.release(holdingOn: true)
        #expect(await eventually { await oliver.service.organized[conversation]?.accepted == [maya.id, jake.id] })
        try await oliver.accept(in: conversation)
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.planned, in: conversation), "\(phone.name)") }
        #expect(await group.lifecyclesWereLegal())
    }

    /// Codex review of #108: sends to one friend can overlap. A late answer
    /// to query Q1 moves the organizer on while the retry Q2 is still
    /// returning, and the yes to proposal P1 is held. Q2 returning first is
    /// stale: it records nothing and leaves the yes held, and P1 returning
    /// counts it once.
    @Test func aStaleQueryReturningLeavesAYesHeldForItsProposal() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let maya = Phone("Maya", hub: hub, maps: maps)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await oliver.hold.release(); await group.stop() } }
        // Maya's phone sends nothing itself; she answers by hand.
        await maya.transport.lose(.max) { _ in true }
        var sequence: UInt64 = 100
        func inject(_ body: MessageBody, in conversation: ConversationID) async throws {
            sequence += 1
            let envelope = try Envelope(conversation: conversation, sender: maya.id, recipient: oliver.id, sequence: sequence,
                                        sentAt: Timestamp(Date()), body: body, skill: skill, mode: .invite)
            try await hub.inject(Frame(EnvelopeCodec().encode(envelope)), claimedSender: maya.id, to: oliver.id)
        }

        await oliver.hold.hold([.query, .propose])
        let conversation = try await oliver.organize([Venues.bobaGuys], with: [maya]).conversation
        // Q1 returns; the retry Q2 stays held.
        #expect(await eventually { await oliver.hold.held.count == 1 })
        let q1 = try #require(await oliver.hold.held.first)
        await oliver.hold.release(q1.id)
        #expect(await eventually { await oliver.hold.held.filter { $0.body.kind == .query }.count == 2 })
        let q2 = await oliver.hold.held[1]
        #expect(await oliver.hold.isHolding(q2.id))

        // Maya's answer to Q1 arrives late. Oliver proposes, and P1 is held.
        try await inject(.answer(Answer(query: q1.id, issue: .place, status: .answered, acceptable: .places([Venues.bobaGuys.choice]))),
                         in: conversation)
        #expect(await oliver.reaches(.proposed, in: conversation))
        #expect(await eventually { await oliver.hold.held.contains { $0.body.kind == .propose } })
        let p1 = try #require(await oliver.hold.held.first { $0.body.kind == .propose })
        guard case .propose(let proposal) = p1.body else { Issue.record("Expected a proposal"); return }

        // Maya's yes to P1 arrives while P1 is still returning.
        try await inject(.accept(Acceptance(proposal: p1.id, terms: proposal.terms)), in: conversation)
        #expect(await eventually { await oliver.service.organized[conversation]?.early[maya.id]?.count == 1 })

        // Q2 returns first.
        await oliver.hold.release(q2.id)
        try await Task.sleep(for: .milliseconds(200))
        let between = try #require(await oliver.service.organized[conversation])
        #expect(between.early[maya.id]?.count == 1)
        #expect(between.accepted.isEmpty)
        #expect(between.queryIDs[maya.id] == [q1.id])

        // Then P1: the held yes counts, once.
        await oliver.hold.release(p1.id)
        #expect(await eventually { await oliver.service.organized[conversation]?.accepted == [maya.id] })
        #expect(await oliver.service.organized[conversation]?.early.isEmpty == true)
        try await oliver.accept(in: conversation)
        #expect(await oliver.reaches(.planned, in: conversation))
        // The roster follows the confirmation as its own event.
        #expect(await eventually { await oliver.attendees(in: conversation) == [oliver.id, maya.id] })
        #expect(await group.lifecyclesWereLegal())
    }

    /// Holding changes when an answer is judged, not what counts: a held
    /// answer naming another friend's query, an unsent query, or a query
    /// from another conversation is dropped once the send returns, and a
    /// friend cannot make the organizer hold more than a few.
    @Test func aHeldAnswerStillHasToNameAQuerySentToThatFriend() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let mallory = Phone("Mallory", hub: hub, maps: maps)
        let maya = Phone("Maya", hub: hub, maps: maps)
        let group = try await Group([oliver, mallory, maya], hub: hub)
        defer { Task { await oliver.hold.release(); await group.stop() } }
        // Neither friend's phone sends anything itself; Mallory answers by
        // hand.
        for friend in [mallory, maya] { await friend.transport.lose(.max) { _ in true } }
        await oliver.hold.hold([.query])
        let request = try await oliver.organize([Venues.bobaGuys], with: [mallory, maya])
        let conversation = request.conversation
        #expect(await eventually { await oliver.hold.held.count == 2 })
        let queries = await oliver.hold.held
        let mallorys = try #require(queries.first { $0.recipient == mallory.id }?.id)
        let mayas = try #require(queries.first { $0.recipient == maya.id }?.id)

        var sequence: UInt64 = 100
        func inject(naming query: MessageID, in conversation: ConversationID) async throws {
            sequence += 1
            let body = MessageBody.answer(try Answer(query: query, issue: .place, status: .answered, acceptable: .places([Venues.bobaGuys.choice])))
            let envelope = try Envelope(conversation: conversation, sender: mallory.id, recipient: oliver.id, sequence: sequence,
                                        sentAt: Timestamp(Date()), body: body, skill: skill, mode: .invite)
            try await hub.inject(Frame(EnvelopeCodec().encode(envelope)), claimedSender: mallory.id, to: oliver.id)
        }
        // Maya's query, an unsent one, and Mallory's own query named in
        // another conversation.
        try await inject(naming: mayas, in: conversation)
        try await inject(naming: MessageID(), in: conversation)
        try await inject(naming: mallorys, in: ConversationID())
        for _ in 0..<6 { try await inject(naming: MessageID(), in: conversation) }
        #expect(await eventually { await oliver.service.organized[conversation]?.early[mallory.id]?.count == PickAPlaceService.maxEarlyReplies })
        #expect(await oliver.service.organized[conversation]?.early[maya.id] == nil)

        await oliver.hold.release()
        #expect(await eventually { await oliver.service.organized[conversation]?.early.isEmpty == true })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await oliver.service.organized[conversation]?.answers.isEmpty == true)

        // The genuine answer is the control.
        try await inject(naming: mallorys, in: conversation)
        #expect(await eventually { await oliver.service.organized[conversation]?.answers[mallory.id] == [Venues.bobaGuys.choice] })
    }
}

/// Issue #121: the friend's side of #105. A friend's answer reaches the
/// organizer before the friend's own send returns (its audit observer
/// still running), so the organizer can propose while the friend still
/// counts itself as answering. The proposal must not be dropped there and
/// left to the organizer's next retry, which a slow or frozen clock may
/// never bring.
@Suite("Replies to a friend that arrive before its send returns", .serialized)
struct FriendEarlyReplyTests {
    /// Retries far slower than any test: only the first send of each
    /// step can move the request on.
    let noRetries = PickAPlaceConfiguration(retryInterval: .seconds(60), maxRetryInterval: .seconds(60),
                                            answerWindow: .seconds(30), confirmWindow: .seconds(30))

    func threeFriends() async throws -> (Group, oliver: Phone, maya: Phone, jake: Phone) {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps, configuration: noRetries)
        let maya = Phone("Maya", hub: hub, maps: maps, configuration: noRetries)
        let jake = Phone("Jake", hub: hub, maps: maps, configuration: noRetries)
        return (try await Group([oliver, maya, jake], hub: hub), oliver, maya, jake)
    }

    @Test func aProposalThatArrivesWhileTheAnswerIsSendingIsShown() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await maya.hold.release(); await group.stop() } }
        await maya.hold.hold([.answer])
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation

        // Oliver has both answers and proposes; Maya's answer send has not
        // returned, so the proposal reaches her while she is answering.
        #expect(await oliver.reaches(.proposed, in: conversation))
        #expect(await jake.reaches(.proposed, in: conversation))
        #expect(await eventually { await group.wire.sent(to: maya.id).contains { $0.conversation == conversation && $0.body.kind == .propose } })
        await maya.hold.release()
        #expect(await maya.reaches(.proposed, in: conversation))
        #expect(await group.wire.sent(by: oliver.id).filter { $0.conversation == conversation && $0.body.kind == .propose && $0.recipient == maya.id }.count == 1)
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aConfirmationThatArrivesWhileTheYesIsSendingIsTaken() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await maya.hold.release(); await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name)") }
        try await jake.accept(in: conversation)
        try await oliver.accept(in: conversation)

        // Maya's yes completes the plan, and Oliver's confirmation reaches
        // her before her own send has returned.
        await maya.hold.hold([.accept])
        let yes = Task { try await maya.accept(in: conversation) }
        #expect(await oliver.reaches(.planned, in: conversation))
        #expect(await eventually { await group.wire.sent(to: maya.id).contains { $0.conversation == conversation && $0.body.kind == .accept } })
        await maya.hold.release()
        try await yes.value
        #expect(await maya.reaches(.planned, in: conversation))
        #expect(await group.lifecyclesWereLegal())
    }
}
