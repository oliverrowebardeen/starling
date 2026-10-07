import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingTransport
import Testing

/// Every peer value is untrusted, and a peer's message never starts
/// anything but an invitee interaction (ARCHITECTURE rule 8).
@Suite("Hostile peers", .serialized)
struct AdversarialTests {
    let skill = PickAPlaceSkill.ref

    /// Maya and a paired friend who misbehaves, sending raw messages.
    func mayaAndMallory(limits mayaLimits: ConstraintSet = .empty, maps: FakeMaps = FakeMaps(Venues.all)) async throws -> (Group, maya: Phone, mallory: Phone) {
        let hub = LoopbackHub()
        let maya = Phone("Maya", hub: hub, maps: maps, limits: mayaLimits)
        let mallory = Phone("Mallory", hub: hub, maps: maps)
        return (try await Group([maya, mallory], hub: hub), maya, mallory)
    }

    func query(_ places: [PlaceChoice]) throws -> MessageBody {
        .query(try Query(issue: .place, candidates: .places(places)))
    }

    @Test func aStrangersRequestIsIgnored() async throws {
        let hub = LoopbackHub()
        let maya = Phone("Maya", hub: hub, maps: FakeMaps(Venues.all))
        let stranger = Phone("Stranger", hub: hub, maps: FakeMaps(Venues.all))
        let group = try await Group([maya], hub: hub)
        defer { Task { await group.stop(); await stranger.stop() } }
        try await stranger.start()
        try await stranger.outbox.send(query([Venues.bobaGuys.choice]), to: maya.id, conversation: ConversationID(), skill: skill, mode: .invite)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await maya.coordinator.incoming.isEmpty)
        #expect(await group.wire.sent(by: maya.id).isEmpty)
    }

    @Test func messagesForAnUnknownConversationStartNothing() async throws {
        let (group, maya, mallory) = try await mayaAndMallory()
        defer { Task { await group.stop() } }
        let roster = MessageBody.propose(try Proposal(round: 0, terms: Terms([
            .place: .places([Venues.bobaGuys.choice]), .people: .peers([mallory.id, maya.id]),
        ])))
        let terms = try Terms([.place: .places([Venues.bobaGuys.choice]), .people: .peers([mallory.id, maya.id])])
        let bodies: [MessageBody] = [
            roster,
            .accept(Acceptance(proposal: MessageID(), terms: terms)),
            .answer(try Answer(query: MessageID(), issue: .place, status: .answered, acceptable: .places([Venues.bobaGuys.choice]))),
            .reject(Rejection(proposal: MessageID(), reason: .noOverlap)),
            // A query about something other than places.
            .query(try Query(issue: .budget, candidates: .amount(usd(5)))),
        ]
        // Mallory's own Outbox requires an answer to name a query; a stray
        // answer names one it never received.
        let stray = OutboundContext(answering: try Query(issue: .place, candidates: .places([Venues.bobaGuys.choice])))
        for body in bodies {
            try await mallory.outbox.send(body, to: maya.id, conversation: ConversationID(), context: body.kind == .answer ? stray : .empty,
                                          skill: skill, mode: .invite, chainedFrom: ConversationID())
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await maya.coordinator.incoming.isEmpty)
        #expect(await group.wire.sent(by: maya.id).isEmpty)
    }

    @Test func chainedFromIsOnlyAHint() async throws {
        let (group, maya, mallory) = try await mayaAndMallory()
        defer { Task { await group.stop() } }
        let claimed = ConversationID()
        try await mallory.outbox.send(query([Venues.bobaGuys.choice]), to: maya.id, conversation: ConversationID(), skill: skill, mode: .invite, chainedFrom: claimed)
        #expect(await eventually { await maya.coordinator.incoming.count == 1 })
        // One invitee interaction, negotiating, with the hint as data. No
        // proposal, no question, no permission.
        let incoming = try #require(await maya.coordinator.incoming.first)
        #expect(incoming.1 == mallory.id && incoming.2 == claimed)
        #expect(await maya.coordinator.state(incoming.0) == .negotiating)
    }

    @Test func aFriendCannotFloodHome() async throws {
        let (group, maya, mallory) = try await mayaAndMallory()
        defer { Task { await group.stop() } }
        for _ in 0..<10 {
            try await mallory.outbox.send(query([Venues.bobaGuys.choice]), to: maya.id, conversation: ConversationID(), skill: skill, mode: .invite)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await maya.coordinator.incoming.count == fastConfiguration.maxLiveRequestsPerFriend)
    }

    /// Sends one-place requests from Mallory, each closed right after.
    func probe(_ count: Int, from mallory: Phone, to maya: Phone, spacing: Duration = .milliseconds(40)) async throws {
        for _ in 0..<count {
            let conversation = ConversationID()
            try await mallory.outbox.send(query([Venues.bobaGuys.choice]), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
            try await Task.sleep(for: spacing)
            try await mallory.outbox.send(.reject(Rejection(proposal: MessageID(), reason: .noOverlap)), to: maya.id,
                                          conversation: conversation, skill: skill, mode: .invite)
        }
    }

    @Test func aClosedRequestStillHoldsItsSlot() async throws {
        let (group, maya, mallory) = try await mayaAndMallory()
        defer { Task { await group.stop() } }
        // Each request is closed straight after its answer, but holds its
        // slot as long as an unanswered one would.
        try await probe(12, from: mallory, to: maya)
        try await Task.sleep(for: .milliseconds(200))
        let lists = await group.wire.sent(by: maya.id).filter { $0.body.kind == .answer }
        #expect(Set(lists.map(\.conversation)).count == fastConfiguration.maxLiveRequestsPerFriend)
    }

    @Test func aFriendCannotProbeWithAnEndlessStreamOfRequests() async throws {
        // Short windows, so slots free quickly and the hourly limit is
        // what stops the stream.
        let short = PickAPlaceConfiguration(retryInterval: .milliseconds(10), maxRetryInterval: .milliseconds(40),
                                            answerWindow: .milliseconds(40), confirmWindow: .milliseconds(20))
        let hub = LoopbackHub()
        let maya = Phone("Maya", hub: hub, maps: FakeMaps(Venues.all), configuration: short)
        let mallory = Phone("Mallory", hub: hub, maps: FakeMaps(Venues.all), configuration: short)
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }
        try await probe(12, from: mallory, to: maya, spacing: .milliseconds(150))
        try await Task.sleep(for: .milliseconds(200))
        let lists = await group.wire.sent(by: maya.id).filter { $0.body.kind == .answer }
        #expect(Set(lists.map(\.conversation)).count == short.maxNewRequestsPerFriendPerHour)
    }

    /// Final privacy review of PR #55: a pass must not free the friend's
    /// slot sooner than an ignored card does, or a fifth request would be
    /// answered after a pass and not after silence.
    @Test(arguments: [true, false])
    func aPassHoldsItsSlotLikeAnIgnoredCard(mayaPasses: Bool) async throws {
        let (group, maya, mallory) = try await mayaAndMallory()
        defer { Task { await group.stop() } }
        let conversations = (0..<fastConfiguration.maxLiveRequestsPerFriend).map { _ in ConversationID() }
        for conversation in conversations {
            try await mallory.outbox.send(query([Venues.bobaGuys.choice]), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        }
        #expect(await eventually { await group.wire.sent(by: maya.id).filter { $0.body.kind == .answer }.count == conversations.count })
        let terms = try Terms([.place: .places([Venues.bobaGuys.choice]), .people: .peers([mallory.id, maya.id])])
        for conversation in conversations {
            try await mallory.outbox.send(.propose(Proposal(round: 0, terms: terms)), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        }
        for conversation in conversations { #expect(await maya.reaches(.proposed, in: conversation)) }
        if mayaPasses { try await maya.pass(in: conversations[0]) }
        try await Task.sleep(for: .milliseconds(100))
        let sentBefore = await group.wire.sent(by: maya.id).count

        // The fifth request.
        let fifth = ConversationID()
        try await mallory.outbox.send(query([Venues.bobaGuys.choice]), to: maya.id, conversation: fifth, skill: skill, mode: .invite)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await group.wire.sent(by: maya.id).count == sentBefore)
        #expect(await maya.interaction(fifth) == nil)
    }

    @Test func aRequestWhoseOrganizerGoesSilentEnds() async throws {
        let quick = PickAPlaceConfiguration(retryInterval: .milliseconds(20), maxRetryInterval: .milliseconds(80),
                                            answerWindow: .milliseconds(300), confirmWindow: .milliseconds(300))
        let hub = LoopbackHub()
        let maya = Phone("Maya", hub: hub, maps: FakeMaps(Venues.all), configuration: quick)
        let mallory = Phone("Mallory", hub: hub, maps: FakeMaps(Venues.all), configuration: quick)
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }
        // Mallory asks, gets Maya's list, and never says anything again.
        let conversation = ConversationID()
        try await mallory.outbox.send(query([Venues.bobaGuys.choice]), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        #expect(await maya.reaches(.negotiating, in: conversation))
        #expect(await maya.reaches(.ended(.expired), in: conversation))
        #expect(await eventually { await maya.service.tasks.isEmpty })
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aRequestInAnotherModeIsIgnored() async throws {
        let (group, maya, mallory) = try await mayaAndMallory()
        defer { Task { await group.stop() } }
        // Pick a place is invite only: a quiet ask never becomes a request.
        try await mallory.outbox.send(query([Venues.bobaGuys.choice]), to: maya.id, conversation: ConversationID(),
                                      skill: skill, mode: .askQuietly)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await maya.coordinator.incoming.isEmpty)
        #expect(await group.wire.sent(by: maya.id).isEmpty)
    }

    @Test func oneConversationAnswersAboutOneSetOfPlaces() async throws {
        let (group, maya, mallory) = try await mayaAndMallory()
        defer { Task { await group.stop() } }
        let conversation = ConversationID()
        try await mallory.outbox.send(query([Venues.bobaGuys.choice]), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        #expect(await eventually { await group.wire.sent(by: maya.id).contains { $0.body.kind == .answer } })
        // Asking again about other places in the same conversation gets
        // nothing, so a friend learns about a bounded set (ADR 0019).
        try await mallory.outbox.send(query([Venues.teaLab.choice, Venues.fancy.choice]), to: maya.id, conversation: conversation,
                                      skill: skill, mode: .invite)
        try await Task.sleep(for: .milliseconds(150))
        let answers = await group.wire.sent(by: maya.id).compactMap { if case .answer(let answer) = $0.body { answer.acceptable } else { nil } }
        #expect(answers == [.places([Venues.bobaGuys.choice])])
    }

    /// Final review of PR #55, finding 1: after the proposal, a repeated
    /// query cannot tell a pass from an undecided card.
    @Test(arguments: [true, false])
    func aRepeatedQueryCannotTellAPassFromAnUndecidedCard(jakePasses: Bool) async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let jake = Phone("Jake", hub: hub, maps: maps)
        let group = try await Group([oliver, jake], hub: hub)
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [jake]).conversation
        #expect(await jake.reaches(.proposed, in: conversation))
        if jakePasses { try await jake.pass(in: conversation) }
        try await Task.sleep(for: .milliseconds(100))
        let before = await group.wire.sent(by: jake.id).count

        // Oliver asks the same question again, twice.
        for _ in 0..<2 {
            try await oliver.outbox.send(query(Venues.all.map(\.choice)), to: jake.id, conversation: conversation,
                                         skill: skill, mode: .invite)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await group.wire.sent(by: jake.id).count == before)
    }

    /// Issue #64 (lane F): an open conversation still rejects a message on
    /// another major version of the skill.
    @Test func anOpenConversationStillRejectsAnIncompatibleSkillMajor() async throws {
        let (group, maya, mallory) = try await mayaAndMallory()
        defer { Task { await group.stop() } }
        let conversation = ConversationID()
        try await mallory.outbox.send(query([Venues.bobaGuys.choice]), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        #expect(await eventually { await group.wire.sent(by: maya.id).contains { $0.body.kind == .answer } })

        let incompatible = SkillRef(.pickAPlace, SkillVersion(2, 0))
        let terms = try Terms([.place: .places([Venues.bobaGuys.choice]), .people: .peers([mallory.id, maya.id])])
        try await mallory.outbox.send(.propose(Proposal(round: 0, terms: terms)), to: maya.id, conversation: conversation,
                                      skill: incompatible, mode: .invite)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await maya.interaction(conversation)?.proposal == nil)
        #expect(await maya.state(in: conversation) == .negotiating)

        // The same proposal at a compatible version is the control.
        try await mallory.outbox.send(.propose(Proposal(round: 0, terms: terms)), to: maya.id, conversation: conversation,
                                      skill: skill, mode: .invite)
        #expect(await maya.reaches(.proposed, in: conversation))
    }

    @Test func aStrangersCardIsNotKept() async throws {
        let hub = LoopbackHub()
        let maya = Phone("Maya", hub: hub, maps: FakeMaps(Venues.all))
        let stranger = Phone("Stranger", hub: hub, maps: FakeMaps(Venues.all))
        let group = try await Group([maya], hub: hub)
        defer { Task { await group.stop(); await stranger.stop() } }
        try await stranger.start()
        try await stranger.hello([maya])
        try await Task.sleep(for: .milliseconds(150))
        #expect(await maya.service.cards[stranger.id] == nil)
    }

    @Test func aProposalForAPlaceMayaDidNotAcceptIsIgnored() async throws {
        let (group, maya, mallory) = try await mayaAndMallory(limits: limits(budget: 20))
        defer { Task { await group.stop() } }
        let conversation = ConversationID()
        try await mallory.outbox.send(query([Venues.fancy.choice, Venues.bobaGuys.choice]), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        #expect(await eventually { await group.wire.sent(by: maya.id).contains { $0.body.kind == .answer } })

        // Le Fancy breaks Maya's budget; a stranger's roster; a budget
        // value; two places. None of these reach Maya's card.
        let stranger = PeerID.random()
        let hostile: [[IssueKey: IssueValue]] = [
            [.place: .places([Venues.fancy.choice]), .people: .peers([mallory.id, maya.id])],
            [.place: .places([Venues.bobaGuys.choice]), .people: .peers([stranger, maya.id])],
            [.place: .places([Venues.bobaGuys.choice]), .people: .peers([mallory.id, maya.id]), .budget: .amount(usd(100))],
            [.place: .places([Venues.bobaGuys.choice, Venues.teaLab.choice]), .people: .peers([mallory.id, maya.id])],
            [.place: .places([Venues.bobaGuys.choice]), .people: .peers([mallory.id])],
        ]
        for terms in hostile {
            try await mallory.outbox.send(.propose(Proposal(round: 0, terms: Terms(terms))), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await maya.state(in: conversation) == .negotiating)
        #expect(await maya.interaction(conversation)?.proposal == nil)
    }

    @Test func aConfirmationThatAddsSomeoneIsIgnored() async throws {
        let (group, maya, mallory) = try await mayaAndMallory()
        defer { Task { await group.stop() } }
        let conversation = ConversationID()
        try await mallory.outbox.send(query([Venues.bobaGuys.choice]), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        #expect(await eventually { await group.wire.sent(by: maya.id).contains { $0.body.kind == .answer } })
        let terms = try Terms([.place: .places([Venues.bobaGuys.choice]), .people: .peers([mallory.id, maya.id])])
        let offer = try await mallory.outbox.send(.propose(Proposal(round: 0, terms: terms)), to: maya.id, conversation: conversation,
                                                  skill: skill, mode: .invite)
        #expect(await maya.reaches(.proposed, in: conversation))
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))

        let padded = try Terms([.place: .places([Venues.bobaGuys.choice]), .people: .peers([mallory.id, maya.id, PeerID.random()])])
        try await mallory.outbox.send(.accept(Acceptance(proposal: offer.id, terms: padded)), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        // A confirmation must confirm Maya's own yes, which named the offer:
        // the right terms naming any other proposal are not one (review of
        // #118, round 2).
        try await mallory.outbox.send(.accept(Acceptance(proposal: MessageID(), terms: terms)), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await maya.state(in: conversation) == .confirmed)

        try await mallory.outbox.send(.accept(Acceptance(proposal: offer.id, terms: terms)), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        #expect(await maya.reaches(.planned, in: conversation))
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aMislabeledVenueIsRejected() async throws {
        // Mallory sends a real Maps identifier under a friendlier name.
        // Maya's phone looks the identifier up and sees another name.
        let (group, maya, mallory) = try await mayaAndMallory()
        defer { Task { await group.stop() } }
        let disguised = try PlaceChoice(name: PlaceName("Green Garden Vegan"), mapItemID: Venues.fancy.choice.mapItemID)
        let conversation = ConversationID()
        try await mallory.outbox.send(query([disguised, Venues.bobaGuys.choice]), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        #expect(await eventually { await group.wire.sent(by: maya.id).contains { $0.body.kind == .answer } })
        let answer = try #require(await group.wire.sent(by: maya.id).first { $0.body.kind == .answer })
        guard case .answer(let body) = answer.body else { return }
        #expect(body.acceptable == .places([Venues.bobaGuys.choice]))
    }

    /// Issue #63 (lane F): an answer must name a query the organizer
    /// actually sent that friend.
    @Test func anAnswerMustNameAQueryTheOrganizerActuallySent() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let mallory = Phone("Mallory", hub: hub, maps: maps)
        let group = try await Group([oliver, mallory], hub: hub)
        defer { Task { await group.stop() } }
        // Mallory's phone sends nothing itself; Mallory answers by hand.
        await mallory.transport.lose(.max) { _ in true }
        let request = try await oliver.organize([Venues.bobaGuys], with: [mallory])
        #expect(await eventually { await group.wire.sent(to: mallory.id).contains { $0.body.kind == .query } })
        let queryID = try #require(await group.wire.sent(to: mallory.id).first { $0.body.kind == .query }?.id)

        func answer(naming query: MessageID, sequence: UInt64) throws -> Frame {
            let body = MessageBody.answer(try Answer(query: query, issue: .place, status: .answered, acceptable: .places([Venues.bobaGuys.choice])))
            return try Frame(EnvelopeCodec().encode(Envelope(conversation: request.conversation, sender: mallory.id, recipient: oliver.id,
                                                             sequence: sequence, sentAt: Timestamp(Date()), body: body, skill: skill, mode: .invite)))
        }
        // An answer naming a query Oliver never sent changes nothing.
        try await hub.inject(answer(naming: MessageID(), sequence: 100), claimedSender: mallory.id, to: oliver.id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await oliver.interaction(request.conversation)?.proposal == nil)

        // The genuine answer is the control.
        try await hub.inject(answer(naming: queryID, sequence: 101), claimedSender: mallory.id, to: oliver.id)
        #expect(await oliver.reaches(.proposed, in: request.conversation))
    }

    @Test func answersAboutPlacesNotAskedAreIgnored() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let mallory = Phone("Mallory", hub: hub, maps: maps)
        let group = try await Group([oliver, mallory], hub: hub)
        defer { Task { await group.stop() } }
        // Mallory's phone sends nothing itself; Mallory answers by hand.
        await mallory.transport.lose(.max) { _ in true }
        let request = try await oliver.organize([Venues.bobaGuys, Venues.teaLab], with: [mallory])
        #expect(await eventually { await group.wire.sent(to: mallory.id).contains { $0.body.kind == .query } })
        let queryID = try #require(await group.wire.sent(to: mallory.id).first { $0.body.kind == .query }?.id)
        let unasked = place("Mallory's Cousin's Bar", id: "I.cousin")
        let answer = try Answer(query: queryID, issue: .place, status: .answered, acceptable: .places([unasked, Venues.teaLab.choice]))
        let frame = try Frame(EnvelopeCodec().encode(Envelope(conversation: request.conversation, sender: mallory.id, recipient: oliver.id,
                                                             sequence: 100, sentAt: Timestamp(Date()), body: .answer(answer), skill: skill, mode: .invite)))
        try await hub.inject(frame, claimedSender: mallory.id, to: oliver.id)
        #expect(await oliver.reaches(.proposed, in: request.conversation))
        #expect(await oliver.interaction(request.conversation)?.proposal?.terms[.place] == .places([Venues.teaLab.choice]))
    }
}
