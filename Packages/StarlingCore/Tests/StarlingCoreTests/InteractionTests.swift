import Foundation
import StarlingCore
import Testing

@Suite struct InteractionTests {
    static let ref = SkillRef(.downFor, SkillVersion(1))
    static func at(_ minutes: Int) -> Timestamp { Timestamp(Fixtures.now.addingTimeInterval(Double(minutes) * 60)) }

    @Test func theHappyPathRunsComposeToRemember() throws {
        var interaction = Interaction(skill: Self.ref, role: .initiator, participants: [Fixtures.bob], createdAt: Self.at(0))
        #expect(interaction.state == .drafting && interaction.state.homeSection == .inProgress)
        let events: [(InteractionEvent, InteractionState, HomeSection)] = [
            (.started, .negotiating, .inProgress),
            (.consentNeeded, .awaitingConsent, .needsYou),
            (.consentGiven, .negotiating, .inProgress),
            (.proposalReady, .proposed, .needsYou),
            (.ownerAccepted, .confirmed, .inProgress),
            (.everyoneConfirmed, .planned, .comingUp),
            (.planEnded, .done, .history),
        ]
        for (index, (event, state, section)) in events.enumerated() {
            try interaction.apply(event, at: Self.at(index + 1))
            #expect(interaction.state == state)
            #expect(interaction.state.homeSection == section)
        }
        #expect(interaction.history.map(\.state) == [.drafting] + events.map(\.1))
        #expect(interaction.updatedAt == Self.at(events.count))
        #expect(LifecycleStep.allCases.allSatisfy { step in interaction.history.contains { $0.state.step == step } || step == .compose })
    }

    @Test func passingAndSilenceEndWithoutAPlan() throws {
        var passed = Interaction(skill: Self.ref, role: .invitee, participants: [Fixtures.alice], createdAt: Self.at(0))
        #expect(passed.state == .negotiating)
        try passed.apply(.proposalReady, at: Self.at(1))
        try passed.apply(.ownerPassed, at: Self.at(2))
        #expect(passed.state == .ended(.declined))

        var nobody = Interaction(skill: Self.ref, role: .initiator, participants: [Fixtures.bob], createdAt: Self.at(0))
        try nobody.apply(.started, at: Self.at(1))
        try nobody.apply(.noAgreement, at: Self.at(2))
        #expect(nobody.state == .ended(.nobodyUp))
        #expect(nobody.state.homeSection == .history)
    }

    @Test func finalStatesAcceptNothingSoLateEventsCannotReviveThem() throws {
        for final in [InteractionState.done, .ended(.declined), .ended(.expired)] {
            for event in [InteractionEvent.started, .proposalReady, .everyoneConfirmed, .withdrawn] {
                #expect(throws: InvalidTransition.self) { try final.applying(event) }
            }
        }
    }

    @Test func eventsOutOfOrderAreRejectedAndLeaveTheInteractionUnchanged() throws {
        var interaction = Interaction(skill: Self.ref, role: .initiator, participants: [Fixtures.bob], createdAt: Self.at(0))
        for event in [InteractionEvent.ownerAccepted, .everyoneConfirmed, .planEnded, .consentGiven] {
            #expect(throws: InvalidTransition.self) { try interaction.apply(event, at: Self.at(1)) }
        }
        #expect(interaction.state == .drafting && interaction.history.count == 1)
        try interaction.apply(.withdrawn, at: Self.at(1))
        #expect(interaction.state == .ended(.withdrawn))
    }

    @Test func artifactsReplaceTheirKindAndTheEgressLogNamesTopics() throws {
        var interaction = Interaction(skill: Self.ref, role: .initiator, participants: [Fixtures.bob], createdAt: Self.at(0))
        let attendees = try Attendees([Fixtures.alice, Fixtures.bob])
        let plan = try Plan(origin: interaction.conversation, attendees: attendees, activity: Keyword("boba"), time: nil)
        interaction.record(.plan(plan))
        let placed = plan.updating(place: try PlaceChoice(name: PlaceName("Boba Guys")))
        interaction.record(.plan(placed))
        #expect(interaction.artifacts.count == 1 && interaction.plan == placed)

        interaction.record(EgressRecord(at: Self.at(1), recipient: Fixtures.bob, items: [
            DisclosedItem(category: .terms, issue: .activity, value: .keywords([try Keyword("boba")])),
            DisclosedItem(category: .terms, issue: .downLevel, value: nil),
            DisclosedItem(category: .agentCard, issue: nil, value: nil),
        ]))
        #expect(interaction.egress.first?.topics == [.activity])
        #expect(try JSONDecoder().decode(Interaction.self, from: JSONEncoder().encode(interaction)) == interaction)
    }

    @Test func aChainListsEveryLinkInTheOrderItStarted() throws {
        let root = Interaction(skill: Self.ref, role: .initiator, participants: [Fixtures.bob], createdAt: Self.at(0))
        func link(_ parent: Interaction, _ skill: SkillID, _ minute: Int) -> Interaction {
            Interaction(skill: SkillRef(skill, SkillVersion(1)), role: .initiator, participants: [Fixtures.bob], createdAt: Self.at(minute),
                        chain: ChainLink(parent: parent.id, parentConversation: parent.conversation, consumed: [.plan], trigger: .atConfirm, optedInAt: Self.at(minute)))
        }
        let place = link(root, .pickAPlace, 8)
        let photos = link(place, .swapPhotos, 9)
        let unrelated = Interaction(skill: Self.ref, role: .invitee, participants: [Fixtures.alice], createdAt: Self.at(5))
        let all = [photos, unrelated, place, root]
        #expect(all.chain(from: root.id).map(\.id) == [root.id, place.id, photos.id])
        #expect(all.chain(from: place.id).map(\.id) == [place.id, photos.id])
    }
}
