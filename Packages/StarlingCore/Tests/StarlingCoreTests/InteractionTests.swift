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
            (.consentNeeded(request: 1), .awaitingConsent(resume: .negotiating), .needsYou),
            (.consentGiven(request: 1), .negotiating, .inProgress),
            (.proposalReady(revision: 1), .proposed, .needsYou),
            (.ownerAccepted(revision: 1), .confirmed, .inProgress),
            (.everyoneConfirmed(revision: 1), .planned, .comingUp),
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
        try passed.apply(.proposalReady(revision: 1), at: Self.at(1))
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
            for event in [InteractionEvent.started, .proposalReady(revision: 1), .everyoneConfirmed(revision: 1), .withdrawn] {
                #expect(throws: InvalidTransition.self) { try final.applying(event) }
            }
        }
    }

    @Test func eventsOutOfOrderAreRejectedAndLeaveTheInteractionUnchanged() throws {
        var interaction = Interaction(skill: Self.ref, role: .initiator, participants: [Fixtures.bob], createdAt: Self.at(0))
        for event in [InteractionEvent.planEnded, .ownerAnswered] {
            #expect(throws: InvalidTransition.self) { try interaction.apply(event, at: Self.at(1)) }
        }
        #expect(throws: UnknownConsentRequest.self) { try interaction.apply(.consentGiven(request: 1), at: Self.at(1)) }
        // No proposal yet, so any acceptance is stale.
        #expect(throws: StaleProposal.self) { try interaction.apply(.ownerAccepted(revision: 1), at: Self.at(1)) }
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

    /// The review's race: the owner taps "I'm in" on proposal 1 after the
    /// service has already shown proposal 2.
    @Test func anAnswerToAnOlderProposalNeverAcceptsNewerTerms() throws {
        var interaction = Interaction(skill: Self.ref, role: .invitee, participants: [Fixtures.alice], createdAt: Self.at(0))
        try interaction.apply(.proposalReady(revision: 1), at: Self.at(1))
        try interaction.apply(.proposalReady(revision: 2), at: Self.at(2))
        #expect(interaction.proposalRevision == 2)
        // The replacement is on the timeline.
        #expect(interaction.history.map(\.state) == [.negotiating, .proposed, .proposed])
        #expect(throws: StaleProposal(current: 2, event: .ownerAccepted(revision: 1))) {
            try interaction.apply(.ownerAccepted(revision: 1), at: Self.at(3))
        }
        #expect(interaction.state == .proposed)
        // Revisions only move forward.
        #expect(throws: StaleProposal.self) { try interaction.apply(.proposalReady(revision: 2), at: Self.at(3)) }
        #expect(throws: StaleProposal.self) { try interaction.apply(.proposalReady(revision: 1), at: Self.at(3)) }

        try interaction.apply(.ownerAccepted(revision: 2), at: Self.at(4))
        // Someone else passed; the agents propose again, and an old
        // confirmation cannot plan the new terms.
        try interaction.apply(.proposalReady(revision: 3), at: Self.at(5))
        #expect(throws: StaleProposal.self) { try interaction.apply(.everyoneConfirmed(revision: 2), at: Self.at(6)) }
        try interaction.apply(.ownerAccepted(revision: 3), at: Self.at(6))
        try interaction.apply(.everyoneConfirmed(revision: 3), at: Self.at(7))
        #expect(interaction.state == .planned)
    }

    /// The review's case: an invitee taps "I'm in", and sending the
    /// acceptance discloses a place set to Ask me.
    @Test func consentCanInterruptAnyLiveStepAndResumesIt() throws {
        var invitee = Interaction(skill: Self.ref, role: .invitee, participants: [Fixtures.alice], createdAt: Self.at(0))
        try invitee.apply(.proposalReady(revision: 1), at: Self.at(1))
        try invitee.apply(.ownerAccepted(revision: 1), at: Self.at(2))
        try invitee.apply(.consentNeeded(request: 7), at: Self.at(3))
        #expect(invitee.state == .awaitingConsent(resume: .confirmed))
        #expect(invitee.state.homeSection == .needsYou && invitee.state.step == .consent)
        try invitee.apply(.consentGiven(request: 7), at: Self.at(4))
        #expect(invitee.state == .confirmed)
        try invitee.apply(.everyoneConfirmed(revision: 1), at: Self.at(5))
        #expect(invitee.state == .planned)

        for resume in ConsentResume.allCases {
            let suspended = try resume.state.applying(.consentNeeded(request: 1))
            #expect(suspended == .awaitingConsent(resume: resume))
            #expect(try suspended.applying(.consentGiven(request: 1)) == resume.state)
            #expect(try suspended.applying(.ownerPassed) == .ended(.declined))
            #expect(try suspended.applying(.noAgreement) == .ended(.nobodyUp))
        }
        // Nothing but consent moves a suspended step.
        #expect(throws: InvalidTransition.self) { try InteractionState.awaitingConsent(resume: .proposed).applying(.everyoneConfirmed(revision: 1)) }
        #expect(throws: InvalidTransition.self) { try InteractionState.planned.applying(.consentNeeded(request: 1)) }
    }

    /// Review 2 of PR #45: two sends in one interaction ask at once.
    @Test func overlappingConsentRequestsResumeOnlyWhenAllAreApproved() throws {
        var interaction = Interaction(skill: Self.ref, role: .initiator, participants: [Fixtures.bob], createdAt: Self.at(0))
        try interaction.apply(.started, at: Self.at(1))
        try interaction.apply(.consentNeeded(request: 1), at: Self.at(2))
        let before = interaction.history.count
        try interaction.apply(.consentNeeded(request: 2), at: Self.at(3))
        #expect(interaction.pendingConsents == [1, 2])
        #expect(interaction.history.count == before)
        try interaction.apply(.consentGiven(request: 1), at: Self.at(4))
        #expect(interaction.state == .awaitingConsent(resume: .negotiating))
        #expect(interaction.state.homeSection == .needsYou)
        // A replayed completion does nothing but throw.
        #expect(throws: UnknownConsentRequest(request: 1)) { try interaction.apply(.consentGiven(request: 1), at: Self.at(5)) }
        #expect(throws: UnknownConsentRequest(request: 2)) { try interaction.apply(.consentNeeded(request: 2), at: Self.at(5)) }
        try interaction.apply(.consentGiven(request: 2), at: Self.at(6))
        #expect(interaction.state == .negotiating && interaction.pendingConsents.isEmpty)
        // A late completion from that round never resumes a new suspension.
        try interaction.apply(.consentNeeded(request: 3), at: Self.at(7))
        #expect(throws: UnknownConsentRequest(request: 2)) { try interaction.apply(.consentGiven(request: 2), at: Self.at(8)) }
        #expect(interaction.state == .awaitingConsent(resume: .negotiating))
        try interaction.apply(.withdrawn, at: Self.at(9))
        #expect(interaction.pendingConsents.isEmpty)
    }
}
