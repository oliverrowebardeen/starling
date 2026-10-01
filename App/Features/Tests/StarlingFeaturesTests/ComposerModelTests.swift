import Foundation
import StarlingCore
import StarlingFakes
@testable import StarlingFeatures
import Testing

@MainActor
final class ComposerHarness {
    let maya = Fixtures.peer("Maya")
    let jake = Fixtures.peer("Jake")
    let leo = Fixtures.peer("Leo")
    let me = PeerID.random()
    let clock = TestClock()
    let down = ScriptedSkillService(descriptor: SampleSkills.downFor)
    let time = ScriptedSkillService(descriptor: SampleSkills.findATime)
    let lifecycle: LifecycleCoordinator
    let settings: SettingsModel
    let cards: PeerCards
    let access: FakeAccess
    let permissions: PermissionGate
    var friends: [PairedPeer]
    var savedRules: OwnerRules?
    var localNetworkPrompts = 0
    var model: ComposerModel!

    init(skillModel: (any SkillModel)? = ComposerHarness.bobaModel(), calendarAnswer: PermissionStatus = .granted) async throws {
        lifecycle = LifecycleCoordinator(registry: SampleSkills.registry, services: [down, time], store: InMemoryInteractionStore(), now: clock.closure)
        settings = SettingsModel(store: InMemoryOwnerSettingsStore(), flags: .phase1_5)
        await settings.load()
        friends = [maya, jake, leo]
        let friendIDs = Set([maya.id, jake.id, leo.id])
        cards = PeerCards(file: nil) { friendIDs.contains($0) }
        access = FakeAccess(.calendarFullAccess, answer: calendarAnswer)
        permissions = PermissionGate(access: [access])
        model = ComposerModel(
            skillModel: skillModel, lifecycle: lifecycle, settings: settings, cards: cards, permissions: permissions,
            friends: { [unowned self] in friends }, savedRules: { [unowned self] in savedRules }, localPeer: me,
            formatter: ValueFormatter(timeZone: Fixtures.utc, locale: Locale(identifier: "en_US"), referenceDate: clock.closure),
            beforeFirstRequest: { [unowned self] in localNetworkPrompts += 1 },
            now: clock.closure
        )
        try give(maya.id, [SampleSkills.downFor.ref, SampleSkills.findATime.ref])
        try give(jake.id, [SampleSkills.findATime.ref])
    }

    func give(_ peer: PeerID, _ skills: [SkillRef]) throws {
        cards.handle(.message(try Envelope(conversation: ConversationID(), sender: peer, recipient: me, sequence: 0, sentAt: Timestamp(Date()),
                                           body: .hello(AgentCard.forBuild(skills: skills, usesPSI: true, locality: .onDevice)))))
    }

    /// "boba tonight with Maya" → Down for… · Boba · Tonight after 7 PM.
    nonisolated static func bobaModel(route: SkillID? = .downFor, names: [String] = []) -> ScriptedSkillModel {
        ScriptedSkillModel(
            onRoute: { _, skills in
                // The model may only answer with a skill it was offered.
                guard let route, skills.contains(where: { $0.id == route }) else { return nil }
                return route
            },
            onIntent: { _, skill in
                let evening = Fixtures.noon.addingTimeInterval(6 * 3600)
                return ParsedIntent(
                    constraints: try ConstraintSet([
                        .activity: [try Constraint(.prefers(liked: [try Keyword("boba")], avoided: []))],
                        .time: [try Constraint(.within([try TimeSlot(start: evening, end: evening.addingTimeInterval(5 * 3600))]))],
                        // Not one of Down for…'s slots: dropped by the composer.
                        .diet: [try Constraint(.prefers(liked: [], avoided: [try Keyword("meat")]))],
                    ]),
                    mentionedNames: names
                )
            }
        )
    }
}

/// Date formats put a narrow no-break space before AM and PM.
func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }

@MainActor
@Suite struct ComposerModelTests {
    @Test func freeTextRoutesToASkillAndFillsItsChips() async throws {
        let h = try await ComposerHarness()
        h.model.text = "boba tonight with whoever's free"
        await h.model.understand()
        #expect(h.model.skill == .downFor)
        #expect(h.model.routedByModel)
        #expect(h.model.skillChip == "Down for boba")
        // Fixtures.noon is 14:13 UTC; six hours later is 20:13, and the
        // slot runs past 11 PM, so "after".
        #expect(h.model.chips.map(plain) == ["Boba", "Tonight after 8:13 PM", "Ask quietly", "Expires in 3 hrs"])
        // Diet is not a Down for… slot.
        #expect(h.model.constraints.constraints[.diet] == nil)
        #expect(h.model.startLabel == "See who's up for it")
        #expect(h.model.footnote == "If nobody's up for it, nobody sees you asked.")
    }

    @Test func namesTheOwnerTypedPickThoseFriends() async throws {
        let h = try await ComposerHarness(skillModel: ComposerHarness.bobaModel(names: ["maya"]))
        h.model.text = "boba with maya"
        await h.model.understand()
        #expect(h.model.audience == .pick)
        #expect(h.model.participants == [h.maya.id])
        #expect(h.model.chips.contains("With Maya"))
    }

    @Test func aNameTwoFriendsShareIsLeftForTheOwner() async throws {
        let h = try await ComposerHarness(skillModel: ComposerHarness.bobaModel(names: ["Alex"]))
        h.friends += [Fixtures.peer("Alex"), Fixtures.peer("Alex")]
        h.model.text = "boba with alex"
        await h.model.understand()
        #expect(h.model.audience == .allFriends)
    }

    @Test func withoutTheModelTheOwnerPicksATile() async throws {
        let h = try await ComposerHarness(skillModel: nil)
        h.model.text = "boba tonight"
        await h.model.understand()
        #expect(h.model.skill == nil)
        #expect(h.model.notice == "Pick what this is below.")
        await h.model.choose(.downFor)
        #expect(h.model.skill == .downFor)
        #expect(!h.model.routedByModel)
        #expect(h.model.blocker == "Add what you want to do, like boba or a walk.")
    }

    @Test func aRouteToNothingKeepsTheOwnersChoice() async throws {
        let h = try await ComposerHarness(skillModel: ComposerHarness.bobaModel(route: nil))
        h.model.text = "hmm"
        await h.model.understand()
        #expect(h.model.skill == nil)
        #expect(h.model.notice == "Starling isn't sure what this is. Pick one below.")
    }

    /// Tiles show every skill in the build, with why one cannot run.
    @Test func tilesExplainSkillsThatCannotRun() async throws {
        let h = try await ComposerHarness()
        await h.settings.set(.never, for: .place)
        await h.settings.setSkill(.findATime, on: false)
        let tiles = Dictionary(uniqueKeysWithValues: h.model.tiles.map { ($0.id, $0) })
        #expect(h.model.tiles.map(\.id) == [.downFor, .findATime, .pickAPlace])
        #expect(tiles[.downFor]?.canStart == true)
        #expect(tiles[.downFor]?.subtitle == "See who's up for something")
        #expect(tiles[.findATime]?.subtitle == "Turned off in You")
        // Pick a place is flagged on but has no service in this build, and
        // its required topic is Never; the build reason comes first.
        #expect(tiles[.pickAPlace]?.subtitle == "Not in this build yet")
        #expect(ComposerModel.blockedReason(SampleSkills.pickAPlace, [.place]) == "Pick a place needs Place. You set Place to Never.")
        // A routed skill never lands on one that cannot run.
        h.model.text = "find a time"
        await h.model.understand()
        #expect(h.model.skill == .downFor)
    }

    @Test func friendsWhoseStarlingCannotRunItAreLeftOutWithANote() async throws {
        let h = try await ComposerHarness()
        h.model.text = "boba"
        await h.model.understand()
        // Jake's card has no Down for…; Leo sent no card yet, so he stays in.
        #expect(h.model.participants == [h.maya.id, h.leo.id])
        #expect(h.model.leftOutNote == "Jake's Starling doesn't do this yet.")
        #expect(h.model.audienceFriends.map(\.canRun) == [true, false, true])
    }

    @Test func closeFriendsAndPickingNarrowTheAudience() async throws {
        let h = try await ComposerHarness()
        await h.settings.setClose(h.leo.id, true)
        h.model.text = "boba"
        await h.model.understand()
        h.model.audience = .closeFriends
        #expect(h.model.participants == [h.leo.id])
        #expect(h.model.chips.contains("Close friends"))
        h.model.toggle(h.leo.id)
        #expect(h.model.audience == .pick)
        #expect(h.model.participants.isEmpty)
        #expect(h.model.blocker == "Pick at least one friend to ask.")
        h.model.toggle(h.maya.id)
        #expect(h.model.participants == [h.maya.id])
    }

    @Test func sendingStartsTheSkillWithTopicsAsSharingAndClearsTheDraft() async throws {
        let h = try await ComposerHarness()
        await h.settings.set(.never, for: .budget)
        h.savedRules = OwnerRules(constraints: try ConstraintSet([.budget: [try Constraint(.atMost(try MoneyAmount(minorUnits: 1500)))]]))
        h.model.text = "boba tonight"
        await h.model.understand()
        let id = try #require(await h.model.send())

        let sent = try #require(await h.down.started.first)
        #expect(sent.interaction == id)
        #expect(sent.participants == [h.maya.id, h.leo.id])
        #expect(sent.intent.audience == .allFriends)
        #expect(sent.intent.rules.constraints.constraints.keys.sorted() == [.activity, .budget, .time])
        #expect(sent.intent.rules.disclosure.contains(DisclosureRule(issue: .budget, action: .never)))
        #expect(sent.intent.expiresAt == Timestamp(h.clock.now.addingTimeInterval(3 * 3600)))
        #expect(h.lifecycle.interaction(id)?.state == .negotiating)
        #expect(h.localNetworkPrompts == 1)
        #expect(h.model.offerNotifications)
        #expect(h.model.text.isEmpty && h.model.skill == nil)
    }

    /// ADR 0013: Find a time shows Starling's sheet before the calendar
    /// alert when the owner starts it, and a denial still sends.
    @Test func findATimeAsksForTheCalendarWhenStartedAndStillRunsOnDenial() async throws {
        let h = try await ComposerHarness(skillModel: ComposerHarness.bobaModel(route: .findATime), calendarAnswer: .denied)
        h.model.text = "find a time with jake next week"
        await h.model.understand()
        #expect(h.model.skill == .findATime)
        let sending = Task { await h.model.send() }
        await eventually { h.permissions.pending != nil }
        #expect(h.permissions.pending?.rows.last?.title == "Maya, Jake and Leo see")
        h.permissions.proceed()
        let id = try #require(await sending.value)
        #expect(h.model.notice == "No problem, your agent will ask you instead.")
        #expect(h.settings.asksInstead(.findATime))
        #expect(await h.time.started.map(\.interaction) == [id])
    }

    @Test func aChainedStepCarriesThePlanItsPeopleAndWhatItAdds() async throws {
        let h = try await ComposerHarness()
        let pick = ScriptedSkillService(descriptor: SampleSkills.pickAPlace)
        let lifecycle = LifecycleCoordinator(registry: SampleSkills.registry, services: [h.down, pick], store: InMemoryInteractionStore(), now: h.clock.closure)
        let model = ComposerModel(
            skillModel: nil, lifecycle: lifecycle, settings: h.settings, cards: h.cards, permissions: h.permissions,
            friends: { [h] in h.friends }, savedRules: { nil }, localPeer: h.me, now: h.clock.closure
        )
        try h.give(h.maya.id, [SampleSkills.downFor.ref, SampleSkills.pickAPlace.ref])

        var parent = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [h.maya.id], createdAt: Timestamp(h.clock.now))
        let plan = try Plan(origin: parent.conversation, attendees: Attendees([h.me, h.maya.id]), activity: Keyword("boba"), time: TimeSlot(start: h.clock.now, end: h.clock.now.addingTimeInterval(3600)))
        parent.record(.plan(plan))

        model.continuePlan(parent, with: SampleSkills.pickAPlace)
        #expect(model.skill == .pickAPlace)
        #expect(model.participants == [h.maya.id])
        #expect(model.chain?.inputs == [.plan(plan), .timeSlot(plan.time!)])
        #expect(model.chain?.link.parent == parent.id)
        #expect(model.chain?.adds == SkillExposure(topics: [.location, .diet], permissions: [.locationWhenInUse]))
        #expect(model.chainAddsNote == "This step also uses your exact location and diet and may ask for your location.")

        let id = try #require(await model.send())
        let sent = try #require(await pick.started.first)
        #expect(sent.chainedFrom == parent.conversation)
        #expect(sent.inputs == [.plan(plan), .timeSlot(plan.time!)])
        #expect(lifecycle.interaction(id)?.chain?.parent == parent.id)
    }

    /// Location is asked when the owner wants nearby places, not at start.
    @Test func nearbyPlacesAskForLocationThroughTheSheet() async throws {
        let h = try await ComposerHarness(skillModel: nil)
        let location = FakeAccess(.locationWhenInUse)
        let gate = PermissionGate(access: [location])
        let pick = ScriptedSkillService(descriptor: SampleSkills.pickAPlace)
        let lifecycle = LifecycleCoordinator(registry: SampleSkills.registry, services: [pick], store: InMemoryInteractionStore(), now: h.clock.closure)
        let model = ComposerModel(skillModel: nil, lifecycle: lifecycle, settings: h.settings, cards: h.cards, permissions: gate,
                                  friends: { [h] in h.friends }, savedRules: { nil }, localPeer: h.me, now: h.clock.closure)
        await model.choose(.pickAPlace)
        #expect(await location.requests == 0)
        let asking = Task { await model.suggestNearby() }
        await eventually { gate.pending != nil }
        #expect(gate.pending?.permission == .locationWhenInUse)
        gate.proceed()
        await asking.value
        #expect(model.chips.first == "Nearby")
        #expect(await location.requests == 1)
    }

    // MARK: Review of PR #54, finding 5

    /// A parser that finishes after the owner narrowed the audience never
    /// overwrites the draft, and Start stays off while it reads.
    @Test func aLateParserResultNeverOverwritesTheOwnersEdits() async throws {
        let gate = Gate()
        let model = ScriptedSkillModel(
            onRoute: { _, _ in .downFor },
            onIntent: { text, skill in
                await gate.wait()
                return try await ComposerHarness.bobaModel(names: ["maya", "jake"]).onIntent(text, skill)
            }
        )
        let h = try await ComposerHarness(skillModel: model)
        h.model.text = "boba with maya and jake"
        let reading = Task { await h.model.understand() }
        await eventually { h.model.isUnderstanding && h.model.skill == .downFor }
        #expect(!h.model.canSend, "Start is off while the model reads")

        h.model.audience = .pick
        h.model.picked = [h.maya.id]
        await gate.open()
        await reading.value

        #expect(h.model.picked == [h.maya.id])
        #expect(h.model.constraints == .empty, "the stale chips were dropped")
        #expect(!h.model.isUnderstanding)
    }

    /// An edit while the calendar sheet is up drops the send: the request
    /// never goes to people the owner did not review.
    @Test func anEditWhileThePermissionSheetIsUpDropsTheSend() async throws {
        let h = try await ComposerHarness(skillModel: ComposerHarness.bobaModel(route: .findATime))
        h.model.text = "find a time next week"
        await h.model.understand()
        let sending = Task { await h.model.send() }
        await eventually { h.permissions.pending != nil }
        h.model.toggle(h.jake.id)
        h.permissions.proceed()
        #expect(await sending.value == nil)
        #expect(await h.time.started.isEmpty)
        #expect(h.model.notice == "You changed the request while Starling was asking. Check it and tap again.")
        #expect(h.lifecycle.interactions.isEmpty)
    }

    @Test func cancelWhileThePermissionSheetIsUpSendsNothing() async throws {
        let h = try await ComposerHarness(skillModel: ComposerHarness.bobaModel(route: .findATime))
        h.model.text = "find a time next week"
        await h.model.understand()
        let sending = Task { await h.model.send() }
        await eventually { h.permissions.pending != nil }
        h.model.clear()
        h.permissions.proceed()
        #expect(await sending.value == nil)
        #expect(await h.time.started.isEmpty)
    }

    /// The request that goes out is the one captured when Start was tapped.
    @Test func theSentRequestIsTheReviewedOne() async throws {
        let h = try await ComposerHarness(skillModel: ComposerHarness.bobaModel(route: .findATime))
        h.model.text = "find a time next week"
        await h.model.understand()
        h.model.audience = .pick
        h.model.picked = [h.jake.id]
        let sending = Task { await h.model.send() }
        await eventually { h.permissions.pending != nil }
        h.permissions.proceed()
        #expect(await sending.value != nil)
        #expect(await h.time.started.map(\.participants) == [[h.jake.id]])
    }

    // MARK: Send modes and audience (ADR 0020)

    @Test func downForOffersBothModesAndSendsTheChosenOne() async throws {
        let h = try await ComposerHarness()
        h.model.text = "boba tonight"
        await h.model.understand()
        #expect(h.model.offersModeChoice)
        #expect(h.model.sendMode == .askQuietly)
        #expect(h.model.footnote == "If nobody's up for it, nobody sees you asked.")
        h.model.mode = .invite
        #expect(h.model.footnote == "The friends you ask see this as an invite.")
        #expect(h.model.chips.contains("Invite"))
        _ = try #require(await h.model.send())
        #expect(await h.down.started.first?.intent.mode == .invite)
    }

    @Test func aSkillWithOneModeOffersNoChoiceAndIgnoresAParsedQuietMode() async throws {
        let model = ScriptedSkillModel(
            onRoute: { _, _ in .findATime },
            onIntent: { _, _ in ParsedIntent(constraints: try ConstraintSet([.time: [try Constraint(.within([try TimeSlot(start: Fixtures.noon, end: Fixtures.noon.addingTimeInterval(3600))]))]]), mode: .askQuietly) }
        )
        let h = try await ComposerHarness(skillModel: model)
        h.model.text = "find a time quietly"
        await h.model.understand()
        #expect(!h.model.offersModeChoice)
        #expect(h.model.sendMode == .invite)
    }

    @Test func aParsedModeAndExceptionBecomeEditableChoices() async throws {
        let model = ScriptedSkillModel(
            onRoute: { _, _ in .downFor },
            onIntent: { [jake = PeerID.random()] _, _ in
                ParsedIntent(constraints: try ConstraintSet([.activity: [try Constraint(.prefers(liked: [try Keyword("boba")], avoided: []))]]),
                             audience: .everyoneExcept([jake]), mode: .invite)
            }
        )
        let h = try await ComposerHarness(skillModel: model)
        h.model.text = "boba, invite everyone but jake"
        await h.model.understand()
        #expect(h.model.sendMode == .invite)
        // An unknown peer in the exception is dropped; the audience stays.
        #expect(h.model.audience == .everyoneExcept)
        #expect(h.model.excepted.isEmpty)
    }

    /// Everyone except leaves the friend out, and nothing is sent to them.
    @Test func everyoneExceptLeavesAFriendOut() async throws {
        let h = try await ComposerHarness()
        h.model.text = "boba"
        await h.model.understand()
        h.model.audience = .everyoneExcept
        h.model.toggle(h.leo.id)
        #expect(h.model.participants == [h.maya.id])
        #expect(h.model.chips.contains("Not Leo"))
        _ = try #require(await h.model.send())
        let sent = try #require(await h.down.started.first)
        #expect(sent.participants == [h.maya.id])
        #expect(sent.intent.audience == .everyoneExcept([h.leo.id]))
    }

    @Test func standingRulesShapeBroadAudiencesButNotPicks() async throws {
        let h = try await ComposerHarness()
        try h.give(h.jake.id, [SampleSkills.downFor.ref, SampleSkills.findATime.ref])
        await h.settings.setRule(.neverInclude, for: h.jake.id)
        await h.settings.setRule(.quietOnly, for: h.leo.id)
        h.model.text = "boba"
        await h.model.understand()
        #expect(h.model.participants == [h.maya.id, h.leo.id], "quiet ask: Leo is in, Jake never")
        h.model.mode = .invite
        #expect(h.model.participants == [h.maya.id], "invite: quiet-only Leo is left out")
        h.model.audience = .pick
        h.model.picked = [h.jake.id]
        #expect(h.model.participants == [h.jake.id], "a pick made now beats the rule")
    }

    @Test func aGroupAsksItsMembers() async throws {
        let h = try await ComposerHarness()
        let group = try FriendGroup(name: "Climbing", members: [h.maya.id, h.jake.id])
        await h.settings.saveGroup(group)
        h.model.text = "boba"
        await h.model.understand()
        #expect(h.model.audienceOptions.map(\.label) == ["All friends", "Close friends", "Climbing", "Everyone except…", "Pick friends"])
        h.model.audience = .group(group.id)
        // Jake's card lacks Down for…, so only Maya goes.
        #expect(h.model.participants == [h.maya.id])
        #expect(h.model.chips.contains("Climbing"))
        h.model.audience = .group(GroupID())
        #expect(h.model.participants.isEmpty)
    }

    /// ADR 0020 decision 9.3: a chained step can reach only the plan's
    /// people, whatever the owner taps.
    @Test func aChainedStepCanOnlyAskThePlansPeople() async throws {
        let h = try await ComposerHarness()
        let pick = ScriptedSkillService(descriptor: SampleSkills.pickAPlace)
        let lifecycle = LifecycleCoordinator(registry: SampleSkills.registry, services: [h.down, pick], store: InMemoryInteractionStore(), now: h.clock.closure)
        let model = ComposerModel(skillModel: nil, lifecycle: lifecycle, settings: h.settings, cards: h.cards, permissions: h.permissions,
                                  friends: { [h] in h.friends }, savedRules: { nil }, localPeer: h.me, now: h.clock.closure)
        try h.give(h.maya.id, [SampleSkills.downFor.ref, SampleSkills.pickAPlace.ref])
        try h.give(h.leo.id, [SampleSkills.downFor.ref, SampleSkills.pickAPlace.ref])
        var parent = Interaction(skill: SampleSkills.downFor.ref, role: .initiator, participants: [h.maya.id], createdAt: Timestamp(h.clock.now))
        parent.record(.plan(try Plan(origin: parent.conversation, attendees: Attendees([h.me, h.maya.id]), activity: Keyword("boba"), time: nil)))
        model.continuePlan(parent, with: SampleSkills.pickAPlace)
        #expect(model.audienceFriends.map(\.id) == [h.maya.id])
        model.audience = .allFriends
        #expect(model.participants == [h.maya.id])
        model.toggle(h.leo.id)
        #expect(!model.participants.contains(h.leo.id))
    }

    /// Re-review of PR #54, finding 1: Down for… after a Find a time plan
    /// takes only the time slot, not the plan, and the plan's people must
    /// still bound who is asked, under All friends and under a group.
    @Test func aChainThatDropsThePlanStillStaysWithinItsPeople() async throws {
        let h = try await ComposerHarness()
        for friend in [h.maya, h.jake, h.leo] { try h.give(friend.id, [SampleSkills.downFor.ref, SampleSkills.findATime.ref]) }
        let group = try FriendGroup(name: "Everyone", members: [h.maya.id, h.jake.id, h.leo.id])
        await h.settings.saveGroup(group)
        await h.settings.setRule(.alwaysInclude, for: h.leo.id)

        var parent = Interaction(skill: SampleSkills.findATime.ref, role: .initiator, participants: [h.maya.id], createdAt: Timestamp(h.clock.now))
        let slot = try TimeSlot(start: h.clock.now, end: h.clock.now.addingTimeInterval(3600))
        parent.record(.plan(try Plan(origin: parent.conversation, attendees: Attendees([h.me, h.maya.id]), activity: nil, time: slot)))
        h.model.continuePlan(parent, with: SampleSkills.downFor)
        #expect(h.model.chain?.inputs == [.timeSlot(slot)], "Down for… accepts the slot only")

        h.model.audience = .allFriends
        #expect(h.model.participants == [h.maya.id])
        h.model.audience = .group(group.id)
        #expect(h.model.participants == [h.maya.id])
        h.model.audience = .everyoneExcept
        #expect(h.model.participants == [h.maya.id])

        h.model.audience = .allFriends
        h.model.text = "boba"
        let constraints = try ConstraintSet([.activity: [try Constraint(.prefers(liked: [try Keyword("boba")], avoided: []))]])
        h.model.constraints = constraints
        _ = try #require(await h.model.send())
        let sent = try #require(await h.down.started.first)
        #expect(sent.participants == [h.maya.id])
        #expect(sent.chainedFrom == parent.conversation)
    }

    @Test func cancelClearsTheDraft() async throws {
        let h = try await ComposerHarness()
        h.model.text = "boba"
        await h.model.understand()
        h.model.audience = .closeFriends
        h.model.clear()
        #expect(h.model.text.isEmpty)
        #expect(h.model.skill == nil)
        #expect(h.model.constraints == .empty)
        #expect(h.model.audience == .allFriends)
    }
}

@Suite struct ChipFormatterTests {
    let formatter = ChipFormatter(values: ValueFormatter(timeZone: Fixtures.utc, locale: Locale(identifier: "en_US")), now: { Fixtures.noon })

    @Test func slotsReadAsDayAndHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Fixtures.utc
        let day = calendar.startOfDay(for: Fixtures.noon)
        func slot(_ from: Double, _ to: Double) throws -> String {
            plain(formatter.slot(try TimeSlot(start: day.addingTimeInterval(from * 3600), end: day.addingTimeInterval(to * 3600))))
        }
        let tonight = try slot(19, 24)
        let today = try slot(10, 14)
        let tomorrow = try slot(34, 38)
        let halfPast = try slot(19.5, 23.5)
        #expect(tonight == "Tonight after 7 PM")
        #expect(today == "Today 10 AM to 2 PM")
        #expect(tomorrow == "Tomorrow 10 AM to 2 PM")
        #expect(halfPast == "Tonight after 7:30 PM")
    }

    @Test func rulesBecomeShortChips() throws {
        let set = try ConstraintSet([
            .budget: [try Constraint(.atMost(try MoneyAmount(minorUnits: 1500)))],
            .place: [try Constraint(.prefers(liked: [try Keyword("nearby")], avoided: []))],
            .activity: [try Constraint(.prefers(liked: [try Keyword("boba")], avoided: [try Keyword("karaoke")]))],
        ])
        #expect(formatter.chips(for: set) == ["Boba", "No karaoke", "Nearby", "Up to $15.00"])
        #expect(formatter.expiry(Fixtures.noon.addingTimeInterval(3 * 3600)) == "Expires in 3 hrs")
        #expect(formatter.expiry(Fixtures.noon.addingTimeInterval(3600)) == "Expires in 1 hr")
        #expect(formatter.expiry(Fixtures.noon.addingTimeInterval(45 * 60)) == "Expires in 45 min")
    }
}

/// Holds a scripted model until the test opens it.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
