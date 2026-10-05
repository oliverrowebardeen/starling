import Foundation
@testable import PickAPlace
import StarlingCore
import StarlingFakes
import StarlingTransport
import Testing

/// `restore(_:)` after the app quits and launches again (ADR 0011).
@Suite("Restore after a restart", .serialized)
struct RestoreTests {
    func oliverAndMaya() async throws -> (Group, oliver: Phone, maya: Phone) {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps)
        let maya = Phone("Maya", hub: hub, maps: maps, limits: limits(budget: 20))
        return (try await Group([oliver, maya], hub: hub), oliver, maya)
    }

    @Test func theOrganizerResumesAProposalAfterARestart() async throws {
        let (group, oliver, maya) = try await oliverAndMaya()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))

        await oliver.restart()
        // The card survived; the owner's yes reaches the new service.
        #expect(await oliver.state(in: conversation) == .proposed)
        try await oliver.accept(in: conversation)
        #expect(await oliver.reaches(.planned, in: conversation))
        #expect(await maya.reaches(.planned, in: conversation))
        #expect(await eventually { await oliver.agreedPlace(in: conversation) == Venues.teaLab.choice })
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aFriendWhoSaidYesSaysItAgainAfterARestart() async throws {
        let (group, oliver, maya) = try await oliverAndMaya()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        // Maya's yes is lost on the way, then her app restarts.
        await maya.transport.lose(.max) { $0.body.kind == .accept }
        try await maya.accept(in: conversation)
        #expect(await maya.reaches(.confirmed, in: conversation))
        await maya.restart()
        await maya.transport.clearRules()

        try await oliver.accept(in: conversation)
        #expect(await oliver.reaches(.planned, in: conversation))
        #expect(await maya.reaches(.planned, in: conversation))
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func bothRestartingStillReachAPlan() async throws {
        let (group, oliver, maya) = try await oliverAndMaya()
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.proposed, in: conversation))
        #expect(await oliver.reaches(.proposed, in: conversation))
        try await oliver.accept(in: conversation)
        await maya.transport.lose(.max) { $0.body.kind == .accept }
        try await maya.accept(in: conversation)
        // Both yeses are in each store before the apps quit.
        #expect(await oliver.reaches(.confirmed, in: conversation))
        #expect(await maya.reaches(.confirmed, in: conversation))
        await oliver.restart()
        await maya.restart()
        await maya.transport.clearRules()
        #expect(await oliver.reaches(.planned, in: conversation))
        #expect(await maya.reaches(.planned, in: conversation))
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aFriendStillDecidingResumesWhenAskedAgain() async throws {
        let (group, oliver, maya) = try await oliverAndMaya()
        defer { Task { await group.stop() } }
        // Maya's list is lost, and her app restarts before it goes out again.
        await maya.transport.lose(.max) { $0.body.kind == .answer }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await eventually { await maya.state(in: conversation) == .negotiating })
        await maya.restart()
        await maya.transport.clearRules()
        #expect(await maya.reaches(.proposed, in: conversation))
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aRestoredRequestLooksFactsUpAgainBeforeANewCard() async throws {
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let maya = Phone("Maya", hub: hub, maps: maps, limits: limits(budget: 20))
        let mallory = Phone("Mallory", hub: hub, maps: maps)
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }
        let skill = PickAPlaceSkill.ref
        let conversation = ConversationID()
        try await mallory.outbox.send(.query(Query(issue: .place, candidates: .places([Venues.bobaGuys.choice]))), to: maya.id,
                                      conversation: conversation, skill: skill, mode: .invite)
        #expect(await eventually { await group.wire.sent(by: maya.id).contains { $0.body.kind == .answer } })
        let first = try Terms([.place: .places([Venues.bobaGuys.choice]), .people: .peers([mallory.id, maya.id])])
        try await mallory.outbox.send(.propose(Proposal(round: 0, terms: first)), to: maya.id, conversation: conversation, skill: skill, mode: .invite)
        #expect(await maya.reaches(.proposed, in: conversation))

        // Maya's app restarts, and Maps now prices Boba Guys over her budget.
        await maya.restart()
        await maps.update(candidate("Boba Guys", id: "I.bobaguys", tier: .four, diets: ["vegan"], kinds: ["boba"]))
        let slot = try TimeSlot(start: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_790_003_600))
        let second = try Terms([.place: .places([Venues.bobaGuys.choice]), .people: .peers([mallory.id, maya.id]), .time: .slots([slot])])
        try await mallory.outbox.send(.propose(Proposal(round: 1, terms: second)), to: maya.id, conversation: conversation, skill: skill, mode: .invite)

        // The new card never shows; Mallory gets an ordinary no.
        #expect(await maya.reaches(.ended(.nobodyUp), in: conversation))
        #expect(await maya.interaction(conversation)?.proposal?.terms == first)
        #expect(await eventually { await group.wire.sent(by: maya.id).contains { $0.body.rejection?.reason == .noOverlap } })
    }

    @Test func aWithdrawnRequestStaysClosedAfterARestart() async throws {
        let (group, oliver, maya) = try await oliverAndMaya()
        defer { Task { await group.stop() } }
        // Maya's list and her goodbye are both lost, so Oliver keeps asking.
        await maya.transport.lose(.max) { $0.body.kind == .answer || $0.body.kind == .reject }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await maya.reaches(.negotiating, in: conversation))
        let id = try #require(await maya.interaction(conversation)?.id)
        await maya.service.withdraw(id)
        #expect(await maya.reaches(.ended(.withdrawn), in: conversation))
        #expect(await eventually { await maya.transport.lost.contains { $0.body.kind == .reject } })

        await maya.restart()
        await maya.transport.clearRules()
        try await Task.sleep(for: .milliseconds(300))
        // Oliver's queries kept coming; Maya's phone sent nothing and
        // opened nothing.
        #expect(await group.wire.sent(to: maya.id).filter { $0.body.kind == .query }.count > 2)
        #expect(await group.wire.sent(by: maya.id).isEmpty)
        #expect(await maya.coordinator.incoming.count == 1)
        #expect(await maya.state(in: conversation) == .ended(.withdrawn))
    }

    @Test(arguments: [false, true])
    func theRequestLimitsSurviveARestart(shortSlots: Bool) async throws {
        // With long slots, the four held slots are what survive; with short
        // ones, the hourly limit of eight.
        let configuration = shortSlots
            ? PickAPlaceConfiguration(retryInterval: .milliseconds(10), maxRetryInterval: .milliseconds(40),
                                      answerWindow: .milliseconds(40), confirmWindow: .milliseconds(20))
            : fastConfiguration
        let limit = shortSlots ? configuration.maxNewRequestsPerFriendPerHour : configuration.maxLiveRequestsPerFriend
        let hub = LoopbackHub()
        let maya = Phone("Maya", hub: hub, maps: FakeMaps(Venues.all), configuration: configuration)
        let mallory = Phone("Mallory", hub: hub, maps: FakeMaps(Venues.all), configuration: configuration)
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }
        let skill = PickAPlaceSkill.ref
        func probe() async throws {
            let conversation = ConversationID()
            try await mallory.outbox.send(.query(Query(issue: .place, candidates: .places([Venues.bobaGuys.choice]))), to: maya.id,
                                          conversation: conversation, skill: skill, mode: .invite)
            try await Task.sleep(for: .milliseconds(shortSlots ? 150 : 40))
            try await mallory.outbox.send(.reject(Rejection(proposal: MessageID(), reason: .noOverlap)), to: maya.id,
                                          conversation: conversation, skill: skill, mode: .invite)
        }
        for _ in 0..<limit { try await probe() }
        try await Task.sleep(for: .milliseconds(100))
        await maya.restart()
        for _ in 0..<3 { try await probe() }
        try await Task.sleep(for: .milliseconds(200))
        let lists = await group.wire.sent(by: maya.id).filter { $0.body.kind == .answer }
        #expect(Set(lists.map(\.conversation)).count == limit)
    }

    @Test func aConversationAnswersAtMostSixteenPlacesAcrossRelaunches() async throws {
        let hub = LoopbackHub()
        let venues = (0..<24).map { candidate("Venue \($0)", id: "I.venue\($0)", tier: .one, kinds: ["cafe"]) }
        let maps = FakeMaps(venues)
        let maya = Phone("Maya", hub: hub, maps: maps)
        let mallory = Phone("Mallory", hub: hub, maps: maps)
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }
        let conversation = ConversationID()
        for round in 0..<3 {
            if round > 0 { await maya.restart() }
            let places = venues[(round * 8)..<(round * 8 + 8)].map(\.choice)
            try await mallory.outbox.send(.query(Query(issue: .place, candidates: .places(places))), to: maya.id,
                                          conversation: conversation, skill: PickAPlaceSkill.ref, mode: .invite)
            try await Task.sleep(for: .milliseconds(200))
        }
        let answered = await group.wire.sent(by: maya.id).flatMap { envelope -> [PlaceChoice] in
            if case .answer(let answer) = envelope.body, case .places(let places)? = answer.acceptable { places } else { [] }
        }
        #expect(Set(answered).count == ProtocolLimits.maxCandidatesAnsweredPerIssue)
        #expect(Set(answered).isSubset(of: venues[0..<16].map(\.choice)))
    }

    @Test func anUnavailableConversationLedgerAnswersNothing() async throws {
        let hub = LoopbackHub()
        let maya = Phone("Maya", hub: hub, maps: FakeMaps(Venues.all))
        let mallory = Phone("Mallory", hub: hub, maps: FakeMaps(Venues.all))
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }
        await maya.conversations.failAll()
        try await mallory.outbox.send(.query(Query(issue: .place, candidates: .places([Venues.bobaGuys.choice, Venues.fancy.choice]))),
                                      to: maya.id, conversation: ConversationID(), skill: PickAPlaceSkill.ref, mode: .invite)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await group.wire.sent(by: maya.id).isEmpty)
        #expect(await maya.coordinator.incoming.isEmpty)
    }

    /// Issue #65 (lane F): a request whose admission cannot be written is
    /// never answered, so a relaunch can never reset the limits.
    @Test func aFailedAdmissionWriteCannotResetTheProbeLimitAfterRestart() async throws {
        let failing = FailedAdmissionLedger()
        let hub = LoopbackHub()
        let maya = Phone("Maya", hub: hub, maps: FakeMaps(Venues.all), placeLedger: failing)
        let mallory = Phone("Mallory", hub: hub, maps: FakeMaps(Venues.all))
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }
        var conversations: [ConversationID] = []
        for _ in 0..<5 {
            let conversation = ConversationID()
            conversations.append(conversation)
            try await mallory.outbox.send(.query(Query(issue: .place, candidates: .places([Venues.bobaGuys.choice]))), to: maya.id,
                                          conversation: conversation, skill: PickAPlaceSkill.ref, mode: .invite)
            try await Task.sleep(for: .milliseconds(100))
            await maya.restart()
        }
        #expect(await failing.attempts == 5)
        #expect(try await failing.admissions(since: .distantPast).isEmpty)
        let asked = Set(conversations)
        #expect(await group.wire.sent(by: maya.id).allSatisfy { !asked.contains($0.conversation) })
        #expect(await maya.coordinator.incoming.isEmpty)
    }

    @Test func anUnreadableLedgerAdmitsNothing() async throws {
        let hub = LoopbackHub()
        let maya = Phone("Maya", hub: hub, maps: FakeMaps(Venues.all))
        let mallory = Phone("Mallory", hub: hub, maps: FakeMaps(Venues.all))
        let group = try await Group([maya, mallory], hub: hub)
        defer { Task { await group.stop() } }
        await maya.ledger.setFailing(true)
        await maya.restart()
        try await mallory.outbox.send(.query(Query(issue: .place, candidates: .places([Venues.bobaGuys.choice]))), to: maya.id,
                                      conversation: ConversationID(), skill: PickAPlaceSkill.ref, mode: .invite)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await maya.coordinator.incoming.isEmpty)
        #expect(await group.wire.sent(by: maya.id).isEmpty)
    }

    @Test func theAppsAdmissionLogKeepsTheLastHour() async throws {
        let suite = "starling.tests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let peer = PeerID.random()
        let now = Date()
        let log = UserDefaultsPickAPlaceLedger(suiteName: suite)
        try await log.recordAdmission(peer, at: now.addingTimeInterval(-4_000))
        try await log.recordAdmission(peer, at: now.addingTimeInterval(-60))
        try await log.recordAdmission(peer, at: now)
        // A new instance reads what the old one wrote, as after a relaunch.
        let reloaded = try await UserDefaultsPickAPlaceLedger(suiteName: suite).admissions(since: now.addingTimeInterval(-3_600))
        #expect(reloaded[peer]?.count == 2)
    }

    /// Re-review of PR #55, finding 2: a restored organizer keeps its
    /// original deadlines.
    func threeWithWindow(_ confirm: Duration) async throws -> (Group, oliver: Phone, maya: Phone, jake: Phone) {
        let window = PickAPlaceConfiguration(retryInterval: .milliseconds(20), maxRetryInterval: .milliseconds(80),
                                             answerWindow: .seconds(3), confirmWindow: confirm)
        let hub = LoopbackHub()
        let maps = FakeMaps(Venues.all)
        let oliver = Phone("Oliver", hub: hub, maps: maps, configuration: window)
        let maya = Phone("Maya", hub: hub, maps: maps, configuration: window)
        let jake = Phone("Jake", hub: hub, maps: maps, configuration: window)
        return (try await Group([oliver, maya, jake], hub: hub), oliver, maya, jake)
    }

    /// Compose keeps a Pick a place open until the plan starts, up to a
    /// week, so the service must take an expiry days away, keep it across
    /// a restart, and not end the request early.
    @Test func aWeekLongRequestRunsToAPlanAndKeepsItsExpiry() async throws {
        let (group, oliver, maya, jake) = try await threeWithWindow(.seconds(1))
        defer { Task { await group.stop() } }
        let week: TimeInterval = 7 * 24 * 3_600
        let before = Date()
        let request = try await oliver.organize(Venues.all, with: [maya, jake], expiresIn: week)
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: request.conversation)) }
        let recorded = try #require(try await oliver.ledger.deadlines(for: request.conversation))
        #expect(abs(recorded.expiresAt.timeIntervalSince(before.addingTimeInterval(week))) < 5)

        await oliver.restart()
        #expect(await oliver.service.organized[request.conversation]?.expiresAt == recorded.expiresAt)
        for phone in [maya, jake, oliver] { try await phone.accept(in: request.conversation) }
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.planned, in: request.conversation)) }
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aRestartPastTheConfirmDeadlineEndsTheRequest() async throws {
        let (group, oliver, maya, jake) = try await threeWithWindow(.milliseconds(600))
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation)) }
        try await maya.accept(in: conversation)
        let deadline = try #require(await oliver.service.organized[conversation]?.confirmDeadline)

        // Oliver's app is gone past the deadline, and back before his own
        // cutoff would have passed.
        try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow) + 0.15))
        await oliver.restart()
        #expect(await oliver.reaches(.ended(.expired), in: conversation, within: 0.2))
        await #expect(throws: PickAPlaceError.notWaitingForYou) { try await oliver.accept(in: conversation) }
        #expect(await maya.reaches(.ended(.expired), in: conversation))
        for phone in [oliver, maya, jake] { #expect(await phone.agreedPlace(in: conversation) == nil) }
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aRestartBeforeTheDeadlineKeepsIt() async throws {
        let (group, oliver, maya, jake) = try await threeWithWindow(.seconds(1))
        defer { Task { await group.stop() } }
        let conversation = try await oliver.organize(Venues.all, with: [maya, jake]).conversation
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.proposed, in: conversation)) }
        let deadline = try #require(await oliver.service.organized[conversation]?.confirmDeadline)
        #expect(try await oliver.ledger.deadlines(for: conversation)?.confirmDeadline == deadline)

        await oliver.restart()
        #expect(await oliver.service.organized[conversation]?.confirmDeadline == deadline)
        for phone in [maya, jake, oliver] { try await phone.accept(in: conversation) }
        for phone in [oliver, maya, jake] { #expect(await phone.reaches(.planned, in: conversation)) }
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func aRequestIsNotSentWhenItsDeadlinesCannotBeKept() async throws {
        let (group, oliver, maya) = try await oliverAndMaya()
        defer { Task { await group.stop() } }
        await oliver.ledger.setFailing(true)
        await #expect(throws: PickAPlaceError.ledgerUnavailable) { try await oliver.organize(Venues.all, with: [maya]) }
        #expect(await group.wire.sent(by: oliver.id).isEmpty)
        #expect(await oliver.coordinator.interactions.values.allSatisfy { $0.state == .ended(.failed) })
    }

    @Test func anOrganizerStillAskingIsReportedFailed() async throws {
        let (group, oliver, maya) = try await oliverAndMaya()
        defer { Task { await group.stop() } }
        await oliver.transport.lose(.max) { $0.body.kind == .query }
        let conversation = try await oliver.organize(Venues.all, with: [maya]).conversation
        #expect(await oliver.reaches(.negotiating, in: conversation))
        await oliver.restart()
        #expect(await oliver.reaches(.ended(.failed), in: conversation))
        #expect(await group.lifecyclesWereLegal())
    }

    @Test func otherVersionsAndUnknownStepsAreReportedFailed() async throws {
        let service = PickAPlaceService(
            localPeer: .random(), outbox: Outbox(transport: RecordingTransport(), policy: FixedPolicyEngine(.allow), consent: ScriptedConsentProvider(.approved)),
            pairedPeers: InMemoryPairedPeerStore(), candidates: StagedCandidates(), maps: FakeMaps(), ownerLimits: { .empty },
            ledger: InMemoryPickAPlaceLedger(), conversations: InMemoryConversationLedger(), plans: { _ in nil }
        )
        let now = Timestamp(Date())
        let otherVersion = Interaction(skill: SkillRef(.pickAPlace, SkillVersion(2, 0)), role: .invitee, participants: [.random()], createdAt: now)
        var askingOwner = Interaction(skill: PickAPlaceSkill.ref, role: .invitee, participants: [.random()], createdAt: now)
        try askingOwner.apply(.ownerNeeded(SkillQuestion(revision: 1, issue: .place, candidates: .places([Venues.bobaGuys.choice]), asker: nil)), at: now)
        let drafting = Interaction(skill: PickAPlaceSkill.ref, role: .initiator, participants: [], createdAt: now)
        let otherSkill = Interaction(skill: SampleSkills.downFor.ref, role: .invitee, participants: [.random()], createdAt: now)

        await service.restore([otherVersion, askingOwner, drafting, otherSkill])
        var reported: [InteractionID] = []
        for await event in service.events {
            if case .lifecycle(let id, .failed) = event { reported.append(id) }
            if reported.count == 2 { break }
        }
        #expect(Set(reported) == [otherVersion.id, askingOwner.id])
    }
}

/// Lane F's fixture: a ledger whose admission writes always throw, while
/// everything else works.
actor FailedAdmissionLedger: PickAPlaceLedger {
    let base = InMemoryPickAPlaceLedger()
    private(set) var attempts = 0
    func admissions(since date: Date) async throws -> [PeerID: [Date]] { try await base.admissions(since: date) }
    func recordAdmission(_ peer: PeerID, at date: Date) async throws { attempts += 1; throw LedgerUnavailable() }
    func pendingWithdrawals() async throws -> [PendingWithdrawal] { try await base.pendingWithdrawals() }
    func recordWithdrawal(_ withdrawal: PendingWithdrawal) async throws { try await base.recordWithdrawal(withdrawal) }
    func clearWithdrawal(_ conversation: ConversationID) async throws { try await base.clearWithdrawal(conversation) }
    func deadlines(for conversation: ConversationID) async throws -> RequestDeadlines? { try await base.deadlines(for: conversation) }
    func recordDeadlines(_ deadlines: RequestDeadlines, for conversation: ConversationID) async throws {
        try await base.recordDeadlines(deadlines, for: conversation)
    }
    func requestKind(for conversation: ConversationID) async throws -> PlaceRequestKind? { try await base.requestKind(for: conversation) }
    func recordRequestKind(_ kind: PlaceRequestKind, for conversation: ConversationID, at date: Date) async throws {
        try await base.recordRequestKind(kind, for: conversation, at: date)
    }
    func yes(for conversation: ConversationID) async throws -> RecordedYes? { try await base.yes(for: conversation) }
    func recordYes(_ yes: RecordedYes, for conversation: ConversationID) async throws { try await base.recordYes(yes, for: conversation) }
}
