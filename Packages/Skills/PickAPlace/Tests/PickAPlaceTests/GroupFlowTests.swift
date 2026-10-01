import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingTransport
import Testing

/// Three venues every phone's maps agree on. Le Fancy is over $20, Tea Lab
/// is known to have nothing vegetarian, Boba Guys is vegan and cheap.
enum Venues {
    static let fancy = candidate("Le Fancy", id: "I.fancy", tier: .four, kinds: ["restaurant"])
    static let teaLab = candidate("Tea Lab", id: "I.tealab", tier: .one, diets: [], kinds: ["boba"])
    static let bobaGuys = candidate("Boba Guys", id: "I.bobaguys", tier: .one, diets: ["vegan"], kinds: ["boba"])
    static let all = [fancy, teaLab, bobaGuys]
}

@Suite("Group flows over Loopback", .serialized)
struct GroupFlowTests {
    /// Oliver organizes; Maya keeps a $20 budget; Jake needs vegetarian.
    func threeFriends(
        jakeLimits: ConstraintSet = limits(needs: ["vegetarian"]),
        jakeSkills: [SkillRef] = [PickAPlaceSkill.ref],
        configuration: PickAPlaceConfiguration = fastConfiguration
    ) async throws -> (Group, oliver: Phone, maya: Phone, jake: Phone) {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps, configuration: configuration)
        let maya = Phone("Maya", hub: hub, maps: maps, limits: limits(budget: 20), configuration: configuration)
        let jake = Phone("Jake", hub: hub, maps: maps, limits: jakeLimits, skills: jakeSkills, configuration: configuration)
        let group = try await Group([oliver, maya, jake], hub: hub)
        return (group, oliver, maya, jake)
    }

    @Test func deniedLocationStillEndsInAPlanThroughManualEntry() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        // Oliver asks for places nearby, sees Starling's sheet, taps
        // Continue, and chooses Don't Allow on the system alert.
        let location = FakeLocation(.notDetermined, answersAlertWith: .denied)
        let finder = PlaceFinder(search: FakeMaps(Venues.all), location: location)
        #expect(await finder.find("dinner", near: .nearby) == .needsLocationPermission)
        #expect(await finder.allowLocationAndFind("dinner") == .manualEntry(.locationDenied))
        #expect(await location.alertsShown == 1)
        #expect(await location.positionReads == 0)

        // He types two places instead.
        let typed = [try PlaceCandidate.manual("Grandma's Kitchen"), try PlaceCandidate.manual("Taco Truck on 5th")]
        let conversation = try await oliver.organize(typed, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation)) }
        for phone in [oliver, maya, jake] { try await phone.accept(in: conversation) }
        for phone in [oliver, maya, jake] {
            #expect(await phone.reaches(.planned, in: conversation))
            #expect(await phone.agreedPlace(in: conversation) == typed[0].choice)
        }
        // A typed place has no coordinate, and nobody's position travels.
        let places: [PlaceChoice] = await group.wire.values.flatMap { (_, value) -> [PlaceChoice] in
            if case .places(let list) = value { list } else { [] }
        }
        #expect(!places.isEmpty && places.allSatisfy { $0.coordinate == nil && $0.mapItemID == nil })
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aGroupOfThreeAgreesOnAPlace() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let request = try await oliver.organize(Venues.all, with: [maya, jake])
        let conversation = request.conversation

        for phone in [oliver, maya, jake] {
            #expect(await phone.reaches(.proposed, in: conversation), "\(phone.name) sees the card")
        }
        // Le Fancy breaks Maya's budget and Tea Lab Jake's diet, so the
        // group answer is the one place that fits everyone.
        let card = try #require(await oliver.interaction(conversation)?.proposal)
        #expect(card.terms[.place] == .places([Venues.bobaGuys.choice]))
        #expect(card.participants == [oliver.id] + [maya.id, jake.id].sorted())
        #expect(await maya.interaction(conversation)?.proposal?.terms == card.terms)

        for phone in [oliver, maya, jake] { try await phone.accept(in: conversation) }
        for phone in [oliver, maya, jake] {
            #expect(await phone.reaches(.planned, in: conversation), "\(phone.name) has a plan")
            #expect(await phone.agreedPlace(in: conversation) == Venues.bobaGuys.choice)
        }
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func budgetAndDietNeverLeaveAnyPhone() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake], limits: limits(budget: 50)).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        for phone in [oliver, maya, jake] { try await phone.accept(in: conversation) }
        #expect(await oliver.reaches(.planned, in: conversation))

        let values = await group.wire.values
        #expect(!values.isEmpty)
        #expect(values.allSatisfy { $0.0 != .budget && $0.0 != .diet })
        #expect(!values.contains { if case .amount = $0.1 { true } else { false } })
        #expect(Set(values.map(\.0)).isSubset(of: [.place, .people]))

        // Each friend sent only the places that fit, best first.
        let answers = await group.wire.envelopes.compactMap { envelope -> (PeerID, IssueValue?)? in
            if case .answer(let answer) = envelope.body { (envelope.sender, answer.acceptable) } else { nil }
        }
        #expect(answers.contains { $0 == (maya.id, .places([Venues.teaLab.choice, Venues.bobaGuys.choice])) })
        #expect(answers.contains { $0 == (jake.id, .places([Venues.bobaGuys.choice])) })
        // Oliver asked only about places within his own limit: Le Fancy is
        // over $50.
        let asked = await group.wire.envelopes.compactMap { if case .query(let query) = $0.body { query.candidates } else { nil } }
        #expect(Set(asked) == [.places([Venues.teaLab.choice, Venues.bobaGuys.choice])])
    }

    @Test func aFriendWhoPassesIsLeftOutAndThePlanGoesAhead() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        #expect(await jake.reaches(.proposed, in: conversation))
        #expect(await maya.reaches(.proposed, in: conversation))

        try await jake.pass(in: conversation)
        try await maya.accept(in: conversation)
        try await oliver.accept(in: conversation)

        #expect(await oliver.reaches(.planned, in: conversation))
        #expect(await maya.reaches(.planned, in: conversation))
        #expect(await jake.state(in: conversation) == .ended(.declined))
        #expect(await jake.agreedPlace(in: conversation) == nil)
        // Oliver and Maya both record who is actually coming.
        for phone in [oliver, maya] {
            #expect(await eventually { await phone.attendees(in: conversation) == [oliver.id, maya.id] }, "\(phone.name)")
        }
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aLateYesNeverUndoesAPass() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation)) }
        try await maya.accept(in: conversation)
        try await maya.pass(in: conversation)
        #expect(await maya.reaches(.ended(.withdrawn), in: conversation))

        // Maya's yes arrives again after her withdrawal, naming a real
        // proposal; Jake sends a yes that names no proposal Oliver sent.
        let proposals = await group.wire.envelopes.filter { $0.body.kind == .propose && $0.recipient == maya.id }
        let terms = try #require(await oliver.interaction(conversation)?.proposal?.terms)
        try await maya.outbox.send(.accept(Acceptance(proposal: try #require(proposals.last).id, terms: terms)), to: oliver.id,
                                   conversation: conversation, skill: PickAPlaceSkill.ref, mode: .invite)
        try await jake.outbox.send(.accept(Acceptance(proposal: MessageID(), terms: terms)), to: oliver.id,
                                   conversation: conversation, skill: PickAPlaceSkill.ref, mode: .invite)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await oliver.service.organized[conversation]?.accepted.isEmpty == true)

        try await jake.accept(in: conversation)
        try await oliver.accept(in: conversation)
        #expect(await oliver.reaches(.planned, in: conversation))
        #expect(await eventually { await oliver.attendees(in: conversation) == [oliver.id, jake.id] })
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func theConfirmDeadlineHoldsBeforeTheOwnerTaps() async throws {
        let quick = PickAPlaceConfiguration(retryInterval: .milliseconds(20), maxRetryInterval: .milliseconds(80),
                                            answerWindow: .seconds(3), confirmWindow: .milliseconds(400))
        let (group, oliver, maya, jake) = try await threeFriends(configuration: quick)
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation)) }
        try await maya.accept(in: conversation)

        // Jake never answers, and the deadline passes before Oliver taps.
        #expect(await jake.reaches(.ended(.expired), in: conversation, within: 2))
        try await oliver.accept(in: conversation)
        #expect(await oliver.reaches(.planned, in: conversation, within: 0.5))
        #expect(await eventually { await oliver.attendees(in: conversation) == [oliver.id, maya.id] })
        #expect(await maya.reaches(.planned, in: conversation))
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func anOwnerWhoNeverConfirmsEndsItForEveryone() async throws {
        let quick = PickAPlaceConfiguration(retryInterval: .milliseconds(20), maxRetryInterval: .milliseconds(80),
                                            answerWindow: .seconds(3), confirmWindow: .milliseconds(300))
        let (group, oliver, maya, jake) = try await threeFriends(configuration: quick)
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation)) }
        try await maya.accept(in: conversation)
        try await jake.accept(in: conversation)
        // Oliver never taps: after the deadline and one more window, the
        // request ends on every phone, and nobody holds a plan.
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.ended(.expired), in: conversation, within: 3), "\(phone.name)") }
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aFriendWhomNothingFitsSaysAnOrdinaryNo() async throws {
        let (group, oliver, maya, jake) = try await threeFriends(jakeLimits: limits(budget: 5, needs: ["halal"], avoid: ["boba"]))
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation

        // Jake's phone answers no, as any no (ADR 0019, decision 5), and
        // never shows the request; Oliver need not wait out the window.
        #expect(await maya.reaches(.proposed, in: conversation, within: 1))
        #expect(await jake.interaction(conversation) == nil)
        #expect(await jake.coordinator.incoming.isEmpty)
        let jakes = await group.wire.sent(by: jake.id)
        #expect(!jakes.isEmpty && jakes.allSatisfy { $0.body.rejection?.reason == .noOverlap })

        let card = try #require(await oliver.interaction(conversation)?.proposal)
        #expect(card.participants == [oliver.id, maya.id])
        try await maya.accept(in: conversation)
        try await oliver.accept(in: conversation)
        #expect(await oliver.reaches(.planned, in: conversation))
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func nobodyUpWhenNoPlaceFitsAnyFriend() async throws {
        let quick = PickAPlaceConfiguration(retryInterval: .milliseconds(20), maxRetryInterval: .milliseconds(80),
                                            answerWindow: .milliseconds(400), confirmWindow: .seconds(3))
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps, configuration: quick)
        let maya = Phone("Maya", hub: hub, maps: maps, limits: limits(budget: 20), configuration: quick)
        let jake = Phone("Jake", hub: hub, maps: maps, limits: limits(avoid: ["restaurant"]), configuration: quick)
        let group = try await Group([oliver, maya, jake], hub: hub)
        defer { Task { await group.stop() } }

        // Le Fancy is over Maya's budget, and Jake avoids restaurants.
        let conversation = try await oliver.organize([Venues.fancy], with: [maya, jake]).conversation
        #expect(await oliver.reaches(.ended(.nobodyUp), in: conversation))
        #expect(await maya.interaction(conversation) == nil)
        #expect(await jake.interaction(conversation) == nil)
        for friend in [maya, jake] {
            #expect(await group.wire.sent(by: friend.id).allSatisfy { $0.body.rejection?.reason == .noOverlap })
        }
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func friendsWhoCannotRunTheSkillAreLeftOut() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let maya = Phone("Maya", hub: hub, maps: maps, limits: limits(budget: 20))
        // Priya's card has no Pick a place; Sam runs a version 2.
        let priya = Phone("Priya", hub: hub, maps: maps, skills: [SampleSkills.downFor.ref])
        let sam = Phone("Sam", hub: hub, maps: maps, skills: [SkillRef(.pickAPlace, SkillVersion(2, 0))])
        let group = try await Group([oliver, maya, priya, sam], hub: hub)
        defer { Task { await group.stop() } }

        let conversation = try await oliver.organize(Venues.all, with: [maya, priya, sam]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        #expect(await oliver.interaction(conversation)?.proposal?.participants == [oliver.id, maya.id])
        // Nothing was sent to either.
        #expect(await group.wire.sent(to: priya.id).isEmpty)
        #expect(await group.wire.sent(to: sam.id).isEmpty)
    }

    @Test func aQueryFromAnotherVersionCreatesNothingAndGetsNoReply() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let maya = Phone("Maya", hub: hub, maps: maps)
        let group = try await Group([oliver, maya], hub: hub)
        defer { Task { await group.stop() } }
        // A Pick a place 2.0 query on fresh conversations: Maya's phone
        // creates nothing and sends nothing, so it cannot be made to send
        // without limit. Oliver's phone leaves her out from her card.
        let query = try Query(issue: .place, candidates: .places([Venues.bobaGuys.choice]))
        for _ in 0..<5 {
            try await oliver.outbox.send(.query(query), to: maya.id, conversation: ConversationID(), recipientCard: maya.card,
                                         skill: SkillRef(.pickAPlace, SkillVersion(2, 0)), mode: .invite)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await group.wire.sent(by: maya.id).isEmpty)
        #expect(await maya.coordinator.incoming.isEmpty)
        #expect(await maya.service.tasks.isEmpty)
    }

    @Test func noWorkIsLeftOnceThereIsAPlan() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation)) }
        for phone in [oliver, maya, jake] { try await phone.accept(in: conversation) }
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.planned, in: conversation)) }
        for phone in [oliver, maya, jake] {
            #expect(await eventually { await phone.service.tasks.isEmpty }, "\(phone.name) still has work")
        }
    }

    @Test func withNoFriendWhoCanRunItTheRequestEndsUnsupported() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let priya = Phone("Priya", hub: hub, maps: maps, skills: [])
        let group = try await Group([oliver, priya], hub: hub)
        defer { Task { await group.stop() } }
        let request = try await oliver.organize(Venues.all, with: [priya])
        #expect(await oliver.reaches(.ended(.unsupported), in: request.conversation))
        #expect(await group.wire.sent(to: priya.id).isEmpty)
    }

    @Test func lostMessagesAreRetried() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        await oliver.transport.lose(2) { $0.body.kind == .query }
        await oliver.transport.lose(1) { $0.body.kind == .propose }
        await maya.transport.lose(1) { $0.body.kind == .answer }
        await maya.transport.lose(1) { $0.body.kind == .accept }
        await oliver.transport.lose(1) { $0.body.kind == .accept }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation)) }
        for phone in [oliver, maya, jake] { try await phone.accept(in: conversation) }
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.planned, in: conversation), "\(phone.name)") }
        #expect(await oliver.transport.lost.count == 4)
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aChainedPickCarriesThePlansTimeAndActivity() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let origin = ConversationID()
        let slot = try TimeSlot(start: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_790_003_600))
        let plan = try Plan(origin: origin, attendees: Attendees([oliver.id, maya.id, jake.id]), activity: kw("boba"), time: slot)
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake], inputs: [.plan(plan)], chainedFrom: origin).conversation

        #expect(await jake.reaches(.proposed, in: conversation))
        let jakes = try #require(await jake.interaction(conversation)?.proposal)
        #expect(jakes.terms[.time] == .slots([slot]))
        #expect(jakes.terms[.activity] == .keywords([kw("boba")]))
        #expect(jakes.plan?.place == Venues.bobaGuys.choice)
        #expect(jakes.plan?.origin == origin)
        // Only the coordinator's grouping hint: chainedFrom reached Jake's
        // phone as data and started nothing else.
        #expect(await jake.coordinator.incoming.map(\.2) == [origin])
        #expect(await oliver.interaction(conversation)?.proposal?.plan?.id == plan.id)
    }

    @Test func staleOrUnexpectedAnswersThrow() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let request = try await oliver.organize(Venues.all, with: [maya, jake])
        await #expect(throws: PickAPlaceError.notWaitingForYou) { try await oliver.service.answer(request.id, with: .accept(proposal: 1)) }
        #expect(await oliver.reaches(.proposed, in: request.conversation))
        await #expect(throws: PickAPlaceError.staleProposal) { try await oliver.service.answer(request.id, with: .accept(proposal: 7)) }
        await #expect(throws: PickAPlaceError.unknownInteraction) { try await oliver.service.answer(InteractionID(), with: .pass) }
        await #expect(throws: PickAPlaceError.alreadyStarted) {
            try await oliver.service.start(SkillRequest(interaction: request.id, conversation: request.conversation,
                                                        intent: SkillIntent(skill: PickAPlaceSkill.ref, rules: .empty, audience: .allFriends, mode: .invite,
                                                                            expiresAt: Timestamp(Date().addingTimeInterval(60))),
                                                        participants: [maya.id]))
        }
    }

    @Test func startNeedsCandidatesThatFitTheOwner() async throws {
        let (group, oliver, maya, _) = try await threeFriends()
        defer { Task { await group.stop() } }
        // Compose checks first, so the owner never sends a request that
        // would end as failed.
        #expect(PickAPlaceSkill.askable([Venues.fancy], limits: limits(budget: 10)).isEmpty)
        #expect(PickAPlaceSkill.askable(Venues.all + Venues.all, limits: limits(budget: 10)) == [Venues.teaLab.choice, Venues.bobaGuys.choice])
        await #expect(throws: PickAPlaceError.noCandidates) { try await oliver.organize([], with: [maya]) }
        await #expect(throws: PickAPlaceError.nothingFitsYourLimits) {
            try await oliver.organize([Venues.fancy], with: [maya], limits: limits(budget: 10))
        }
        #expect(await group.wire.sent(by: oliver.id).isEmpty)
        let failed = await oliver.coordinator.interactions.values.filter { $0.state == .ended(.failed) }
        #expect(failed.count == 2)
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func withdrawingTellsFriendsNoPlan() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let request = try await oliver.organize(Venues.all, with: [maya, jake])
        #expect(await maya.reaches(.proposed, in: request.conversation))
        await oliver.service.withdraw(request.id)
        #expect(await oliver.reaches(.ended(.withdrawn), in: request.conversation))
        #expect(await maya.reaches(.ended(.nobodyUp), in: request.conversation))
        #expect(await jake.reaches(.ended(.nobodyUp), in: request.conversation))
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func anExpiredRequestEndsForEveryone() async throws {
        let (group, oliver, maya, jake) = try await threeFriends()
        defer { Task { await group.stop() } }
        let request = try await oliver.organize(Venues.all, with: [maya, jake], expiresIn: 0.5)
        #expect(await maya.reaches(.proposed, in: request.conversation))
        #expect(await oliver.reaches(.ended(.expired), in: request.conversation))
        #expect(await maya.reaches(.ended(.expired), in: request.conversation))
        #expect(await group.lifecyclesWereLegal())
    }
}

extension MessageBody {
    var rejection: Rejection? { if case .reject(let rejection) = self { rejection } else { nil } }
}
