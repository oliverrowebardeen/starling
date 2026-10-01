import Foundation
import StarlingCore
import StarlingFakes
import StarlingSwapPhotos
import Testing

enum Fixtures {
    static let me = try! PeerID(bytes: Data(repeating: 0xAA, count: 32))
    static let maya = try! PeerID(bytes: Data(repeating: 0xBB, count: 32))
    static let jake = try! PeerID(bytes: Data(repeating: 0xCC, count: 32))
    static let stranger = try! PeerID(bytes: Data(repeating: 0xDD, count: 32))
    /// 2026-10-02 19:00:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_790_967_600)
    static func date(minutes: Int) -> Date { now.addingTimeInterval(Double(minutes) * 60) }
    static func at(minutes: Int) -> Timestamp { Timestamp(date(minutes: minutes)) }
    static let tonight = try! TimeSlot(start: date(minutes: 90), end: date(minutes: 210))
    static let afterTonight = date(minutes: 211)
    static let parentConversation = ConversationID()
    static let plan = try! Plan(origin: parentConversation, attendees: Attendees([me, maya, jake]), activity: Keyword("boba"), time: tonight)

    static func request(chainedFrom: ConversationID? = parentConversation, inputs: [Artifact] = [.plan(plan)], participants: [PeerID] = [maya, jake],
                        skill: SkillRef = SwapPhotos.descriptor.ref) -> SkillRequest {
        SkillRequest(
            interaction: InteractionID(), conversation: ConversationID(),
            intent: SkillIntent(skill: skill, rules: .empty, audience: .picked(participants), expiresAt: at(minutes: 24 * 60)),
            participants: participants, inputs: inputs, chainedFrom: chainedFrom
        )
    }

    static func offer(count: Int = 5, from sender: PeerID = maya, to recipient: PeerID = me, conversation: ConversationID = ConversationID(),
                      chainedFrom: ConversationID? = parentConversation, skill: SkillRef = SwapPhotos.descriptor.ref,
                      terms: Terms? = nil) throws -> Envelope {
        try Envelope(conversation: conversation, sender: sender, recipient: recipient, sequence: 0, sentAt: Timestamp(afterTonight),
                     body: .propose(Proposal(round: 0, terms: terms ?? Terms([.photos: .count(count)]))), skill: skill, chainedFrom: chainedFrom)
    }
}

struct Phone {
    let service: SwapPhotosService
    let transport: RecordingTransport

    init(policy: PolicyDecision = .allow, now: Date = Fixtures.afterTonight) {
        self.init(now: now) { transport in
            Outbox(transport: transport, policy: FixedPolicyEngine(policy), consent: ScriptedConsentProvider(.approved), now: { now })
        }
    }

    /// A phone whose Outbox the test builds around its transport.
    init(now: Date = Fixtures.afterTonight, outbox: (RecordingTransport) -> Outbox) {
        let knownPlans = [Fixtures.parentConversation: Fixtures.plan]
        transport = RecordingTransport(localPeer: Fixtures.me)
        service = SwapPhotosService(outbox: outbox(transport), me: Fixtures.me, planLookup: { knownPlans[$0] }, now: { now })
    }

    func sent() async throws -> [Envelope] {
        try await transport.sent.map { try EnvelopeCodec().decode($0.frame.bytes) }
    }

    /// Every event so far. Ends the service's stream.
    func events() async -> [SkillEvent] {
        await service.shutdown()
        var all: [SkillEvent] = []
        for await event in service.events { all.append(event) }
        return all
    }
}

@Suite struct SwapPhotosSkillTests {
    @Test func itIsTheSampleDescriptorAndShipsFlaggedOff() {
        #expect(SwapPhotos.descriptor == SampleSkills.swapPhotos)
        #expect(SwapPhotos.descriptor.chainTrigger == .afterPlanEnds)
        #expect(!SwapPhotos.isEnabled(in: .phase1_5))
        #expect(SampleSkills.registry.availability(of: .swapPhotos, in: SkillSettings(flags: .phase1_5)) == .notInThisBuild)
    }

    @Test func thePickersAnswerFitsTheQuestion() {
        let question = SwapPhotos.pickQuestion(revision: 3)
        #expect(SwapPhotos.answer(picked: 4, to: question) == .reply(question: 3, .count(4)))
        #expect(SwapPhotos.answer(picked: 0, to: question) == nil)
        #expect(SwapPhotos.answer(picked: SwapPhotos.maxPhotos + 1, to: question) == nil)
        #expect(SwapPhotos.answer(picked: 1, to: SkillQuestion(revision: 1, issue: .time, candidates: .count(5), asker: nil)) == nil)
    }
}

@Suite struct SwapPhotosServiceTests {
    @Test func itStartsOnlyAsALinkAfterAPlanThatHasEnded() async throws {
        let phone = Phone()
        await #expect(throws: SwapPhotosError.notChained) { try await phone.service.start(Fixtures.request(chainedFrom: nil)) }
        await #expect(throws: SwapPhotosError.noPlan) { try await phone.service.start(Fixtures.request(inputs: [])) }
        await #expect(throws: SwapPhotosError.noPlan) { try await phone.service.start(Fixtures.request(chainedFrom: ConversationID())) }
        await #expect(throws: SwapPhotosError.notInThePlan) { try await phone.service.start(Fixtures.request(participants: [Fixtures.stranger])) }
        await #expect(throws: SwapPhotosError.notInThePlan) { try await phone.service.start(Fixtures.request(participants: [])) }
        await #expect(throws: SwapPhotosError.wrongSkill) { try await phone.service.start(Fixtures.request(skill: SampleSkills.pickAPlace.ref)) }

        let early = Phone(now: Fixtures.date(minutes: 200))
        await #expect(throws: SwapPhotosError.planNotOver) { try await early.service.start(Fixtures.request()) }
        #expect(await phone.events().isEmpty)
        #expect(try await phone.sent().isEmpty)
    }

    @Test func startingAsksTheOwnerToPickAndSendsNothing() async throws {
        let phone = Phone()
        let request = Fixtures.request()
        try await phone.service.start(request)
        await #expect(throws: SwapPhotosError.alreadyStarted(request.interaction)) { try await phone.service.start(request) }
        #expect(try await phone.sent().isEmpty)
        // The coordinator applies .started for an initiator; the service never does.
        #expect(await phone.events() == [.lifecycle(request.interaction, .ownerNeeded(SwapPhotos.pickQuestion(revision: 1)))])
    }

    @Test func theOwnersPickSendsOneOfferToEveryoneInThePlanWithChainedFrom() async throws {
        let phone = Phone()
        let request = Fixtures.request()
        try await phone.service.start(request)
        await #expect(throws: SwapPhotosError.unexpectedAnswer(request.interaction)) {
            try await phone.service.answer(request.interaction, with: .reply(question: 2, .count(3)))
        }
        try await phone.service.answer(request.interaction, with: .reply(question: 1, .count(3)))
        let sent = try await phone.sent()
        #expect(sent.map(\.recipient) == [Fixtures.maya, Fixtures.jake])
        #expect(sent.allSatisfy { $0.chainedFrom == Fixtures.parentConversation && $0.skill == SwapPhotos.descriptor.ref && $0.conversation == request.conversation })
        #expect(sent.allSatisfy { $0.body == .propose(try! Proposal(round: 0, terms: Terms([.photos: .count(3)]))) })
        #expect(await phone.events().suffix(1) == [.lifecycle(request.interaction, .ownerAnswered(question: 1))])
    }

    @Test func passingOnThePickSendsNothing() async throws {
        let phone = Phone()
        let request = Fixtures.request()
        try await phone.service.start(request)
        try await phone.service.answer(request.interaction, with: .pass)
        #expect(try await phone.sent().isEmpty)
        #expect(await phone.events().last == .lifecycle(request.interaction, .ownerPassed))
    }

    @Test func photosSetToNeverEndsTheLinkBlockedByPrivacy() async throws {
        let phone = Phone(policy: .deny(PolicyViolation(rule: "disclosure.never", issue: .photos)))
        let request = Fixtures.request()
        try await phone.service.start(request)
        try await phone.service.answer(request.interaction, with: .reply(question: 1, .count(2)))
        #expect(try await phone.sent().isEmpty)
        #expect(await phone.events().last == .lifecycle(request.interaction, .blockedByPrivacy))
    }

    @Test func acceptancesFromThePlanAreCollected() async throws {
        let phone = Phone()
        let request = Fixtures.request()
        try await phone.service.start(request)
        try await phone.service.answer(request.interaction, with: .reply(question: 1, .count(3)))
        let offer = try #require(try await phone.sent().first)
        let terms = try Terms([.photos: .count(3)])
        for (sender, accepted) in [(Fixtures.maya, terms), (Fixtures.stranger, terms), (Fixtures.jake, try Terms([.photos: .count(9)]))] {
            let reply = try Envelope(conversation: request.conversation, sender: sender, recipient: Fixtures.me, sequence: 0, sentAt: Timestamp(Fixtures.afterTonight),
                                     body: .accept(Acceptance(proposal: offer.id, terms: accepted)), skill: SwapPhotos.descriptor.ref, chainedFrom: Fixtures.parentConversation)
            await phone.service.handle(.message(reply))
        }
        // The stranger is not in the plan, and Jake accepted other terms.
        #expect(await phone.service.acceptedOffer(request.interaction) == [Fixtures.maya])
    }

    @Test func restoringResumesAnUnansweredPickAndFailsTheRest() async throws {
        let phone = Phone()
        func link(_ events: [InteractionEvent]) throws -> Interaction {
            var interaction = Interaction(skill: SwapPhotos.descriptor.ref, role: .initiator, participants: [Fixtures.maya], createdAt: Fixtures.at(minutes: 6),
                                          chain: ChainLink(parent: InteractionID(), parentConversation: Fixtures.parentConversation, consumed: [.plan],
                                                           trigger: .afterPlanEnds, optedInAt: Fixtures.at(minutes: 6)))
            for event in events { try interaction.apply(event, at: Fixtures.at(minutes: 211)) }
            return interaction
        }
        let picking = try link([.started, .ownerNeeded(SwapPhotos.pickQuestion(revision: 1))])
        let offered = try link([.started, .ownerNeeded(SwapPhotos.pickQuestion(revision: 1)), .ownerAnswered(question: 1)])
        let waiting = try link([])
        await phone.service.restore([picking, offered, waiting])
        try await phone.service.answer(picking.id, with: .reply(question: 1, .count(1)))
        #expect(try await phone.sent().map(\.chainedFrom) == [Fixtures.parentConversation])
        let events = await phone.events()
        #expect(events.contains(.lifecycle(offered.id, .failed)))
        #expect(!events.contains { if case .lifecycle(let id, _) = $0 { id == waiting.id } else { false } })
    }
}

@Suite struct SwapPhotosAsAFriendTests {
    @Test func anOfferCreatesOnlyAnInviteeCardNeverThePickerOrAPermission() async throws {
        let phone = Phone()
        let offer = try Fixtures.offer()
        await phone.service.handle(.message(offer))
        let events = await phone.events()
        #expect(events.count == 2)
        guard case .incoming(let id, let conversation, let from, let chainedFrom) = events.first else {
            Issue.record("expected an incoming interaction, got \(events)")
            return
        }
        #expect(conversation == offer.conversation && from == Fixtures.maya && chainedFrom == Fixtures.parentConversation)
        #expect(events.last == .lifecycle(id, .proposalReady(SkillProposal(revision: 1, participants: [Fixtures.maya, Fixtures.me],
                                                                            terms: try Terms([.photos: .count(5)])))))
        // No question to the owner (the picker), no start, nothing sent.
        #expect(!events.contains { if case .lifecycle(_, .ownerNeeded) = $0 { true } else { false } })
        #expect(!events.contains { if case .lifecycle(_, .started) = $0 { true } else { false } })
        #expect(try await phone.sent().isEmpty)
    }

    @Test func offersOutsideAPlanThisPhoneWasInAreDropped() async throws {
        let phone = Phone()
        // No chainedFrom; a plan this phone does not know; a sender who was
        // not in the plan; another skill; terms beyond a photo count; too many.
        let offers = [
            try Fixtures.offer(chainedFrom: nil),
            try Fixtures.offer(chainedFrom: ConversationID()),
            try Fixtures.offer(from: Fixtures.stranger),
            try Fixtures.offer(skill: SampleSkills.pickAPlace.ref),
            try Fixtures.offer(terms: Terms([.photos: .count(2), .time: .slots([Fixtures.tonight])])),
            try Fixtures.offer(count: SwapPhotos.maxPhotos + 1),
            try Fixtures.offer(count: 0),
        ]
        for offer in offers { await phone.service.handle(.message(offer)) }
        #expect(await phone.events().isEmpty)
        #expect(try await phone.sent().isEmpty)
    }

    @Test func sharingAcceptsTheOfferAndPassingStaysSilent() async throws {
        let phone = Phone()
        let offer = try Fixtures.offer()
        await phone.service.handle(.message(offer))
        let second = try Fixtures.offer(from: Fixtures.jake)
        await phone.service.handle(.message(second))
        let ids: [InteractionID] = await {
            var ids: [InteractionID] = []
            // Peek at the two incoming interactions without ending the stream.
            var iterator = phone.service.events.makeAsyncIterator()
            while ids.count < 2, let event = await iterator.next() {
                if case .incoming(let id, _, _, _) = event { ids.append(id) }
            }
            return ids
        }()
        try await phone.service.answer(ids[0], with: .accept(proposal: 1))
        try await phone.service.answer(ids[1], with: .pass)
        let sent = try await phone.sent()
        #expect(sent.count == 1)
        #expect(sent.first?.recipient == Fixtures.maya)
        #expect(sent.first?.chainedFrom == Fixtures.parentConversation)
        #expect(sent.first?.body == .accept(Acceptance(proposal: offer.id, terms: try Terms([.photos: .count(5)]))))
        let rest = await phone.events()
        #expect(rest.contains(.lifecycle(ids[0], .ownerAccepted(revision: 1))))
        #expect(rest.contains(.lifecycle(ids[1], .ownerPassed)))
    }

    @Test func aNewerOfferFromTheSameFriendReplacesTheCard() async throws {
        let phone = Phone()
        let conversation = ConversationID()
        let first = try Fixtures.offer(count: 5, conversation: conversation)
        await phone.service.handle(.message(first))
        var iterator = phone.service.events.makeAsyncIterator()
        guard case .incoming(let id, _, _, _) = await iterator.next() else {
            Issue.record("expected an incoming interaction")
            return
        }
        _ = await iterator.next()
        // Ignored: someone else in the same conversation, another plan, and
        // too many photos.
        await phone.service.handle(.message(try Fixtures.offer(count: 2, from: Fixtures.jake, conversation: conversation)))
        await phone.service.handle(.message(try Fixtures.offer(count: 2, conversation: conversation, chainedFrom: ConversationID())))
        await phone.service.handle(.message(try Fixtures.offer(count: SwapPhotos.maxPhotos + 1, conversation: conversation)))
        let second = try Fixtures.offer(count: 2, conversation: conversation)
        await phone.service.handle(.message(second))
        #expect(await iterator.next() == .lifecycle(id, .proposalReady(SkillProposal(revision: 2, participants: [Fixtures.maya, Fixtures.me],
                                                                                         terms: try Terms([.photos: .count(2)])))))
        // The older card can no longer be accepted; the newer one can.
        await #expect(throws: SwapPhotosError.unexpectedAnswer(id)) { try await phone.service.answer(id, with: .accept(proposal: 1)) }
        try await phone.service.answer(id, with: .accept(proposal: 2))
        let sent = try await phone.sent()
        #expect(sent.map(\.body) == [.accept(Acceptance(proposal: second.id, terms: try Terms([.photos: .count(2)])))])
        #expect(await iterator.next() == .lifecycle(id, .ownerAccepted(revision: 2)))
    }
}
