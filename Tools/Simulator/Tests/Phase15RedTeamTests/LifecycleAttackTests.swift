import Foundation
import StarlingCore
import StarlingFakes
import Testing

@Suite struct LifecycleAttackTests {
    @Test(arguments: SampleSkills.all)
    func restartPreservesEverySuspendedStep(skill: SkillDescriptor) async throws {
        for resume in ConsentResume.allCases {
            var interaction = P15.interaction(skill)
            if resume == .awaitingOwner { try interaction.apply(.ownerNeeded(P15.question(7)), at: P15.now) }
            if resume == .proposed || resume == .confirmed {
                try interaction.apply(.proposalReady(P15.proposal(7)), at: P15.now)
            }
            if resume == .confirmed { try interaction.apply(.ownerAccepted(revision: 7), at: P15.now) }
            try interaction.apply(.consentNeeded(request: 9), at: P15.now)
            try interaction.apply(.consentNeeded(request: 10), at: P15.now)
            let store = InMemoryInteractionStore([try P15.restart(interaction)])
            let service = ScriptedSkillService(descriptor: skill)
            try await service.restore(store.all())
            var restored = try #require(await store.interaction(interaction.id))
            #expect(await service.restored == [interaction])
            #expect(restored.pendingConsents == [9, 10])
            #expect(restored.state == .awaitingConsent(resume: resume))
            let snapshot = restored
            #expect(throws: UnknownConsentRequest.self) { try restored.apply(.consentGiven(request: 8), at: P15.now) }
            #expect(throws: UnknownConsentRequest.self) { try restored.apply(.consentNeeded(request: 9), at: P15.now) }
            #expect(throws: InvalidTransition.self) { try restored.apply(.proposalReady(P15.proposal(8)), at: P15.now) }
            #expect(restored == snapshot)
            try restored.apply(.consentGiven(request: 10), at: P15.now)
            #expect(restored.state == .awaitingConsent(resume: resume))
            restored = try P15.restart(restored)
            #expect(throws: UnknownConsentRequest.self) { try restored.apply(.consentGiven(request: 10), at: P15.now) }
            try restored.apply(.consentGiven(request: 9), at: P15.now)
            #expect(restored.state == resume.state)
            #expect(restored.proposal == interaction.proposal)
            #expect(restored.pendingQuestion == interaction.pendingQuestion)
            await service.shutdown()
        }
    }

    @Test(arguments: SampleSkills.all)
    func oldCardsCannotAcceptReplacementTermsAfterRestart(skill: SkillDescriptor) throws {
        var interaction = P15.interaction(skill)
        try interaction.apply(.proposalReady(P15.proposal(1)), at: P15.now)
        try interaction.apply(.ownerAccepted(revision: 1), at: P15.now)
        try interaction.apply(.proposalReady(P15.proposal(2, activity: "tacos")), at: P15.now)
        interaction = try P15.restart(interaction)
        for event in [InteractionEvent.ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1),
                      .proposalReady(try P15.proposal(2, activity: "share all photos"))] {
            let snapshot = interaction
            #expect(throws: StaleProposal.self) { try interaction.apply(event, at: P15.now) }
            #expect(interaction == snapshot)
        }
        try interaction.apply(.ownerAccepted(revision: 2), at: P15.now)
        try interaction.apply(.everyoneConfirmed(revision: 2), at: P15.now)
        #expect(interaction.state == .planned)
        #expect(interaction.proposal == (try P15.proposal(2, activity: "tacos")))
    }

    @Test func completedQuestionsAndConsentCannotWrapOrReopen() throws {
        var interaction = P15.interaction()
        try interaction.apply(.ownerNeeded(P15.question(.max)), at: P15.now)
        try interaction.apply(.ownerAnswered(question: .max), at: P15.now)
        try interaction.apply(.consentNeeded(request: .max), at: P15.now)
        try interaction.apply(.consentGiven(request: .max), at: P15.now)
        interaction = try P15.restart(interaction)
        for revision: UInt32 in [0, 1, .max - 1, .max] {
            let snapshot = interaction
            #expect(throws: StaleQuestion.self) { try interaction.apply(.ownerNeeded(P15.question(revision)), at: P15.now) }
            #expect(throws: UnknownConsentRequest.self) { try interaction.apply(.consentNeeded(request: revision), at: P15.now) }
            #expect(interaction == snapshot)
        }
        // Exhaustion fails closed but does not trap the owner in a live request.
        try interaction.apply(.withdrawn, at: P15.now)
        #expect(interaction.state == .ended(.withdrawn))
    }

    @Test func everyLateLifecycleEventLeavesEveryFinalRecordUnchanged() throws {
        let endings: [InteractionEvent] = [.ownerPassed, .noAgreement, .expired, .withdrawn, .failed, .unsupported, .blockedByPrivacy, .planEnded]
        let attacks: [InteractionEvent] = [
            .started, .consentNeeded(request: 30), .consentGiven(request: 1),
            .ownerNeeded(try P15.question(30)), .ownerAnswered(question: 1),
            .proposalReady(try P15.proposal(30)), .ownerAccepted(revision: 1),
            .everyoneConfirmed(revision: 1), .ownerPassed, .noAgreement,
            .expired, .withdrawn, .failed, .unsupported, .blockedByPrivacy, .planEnded,
        ]
        for ending in endings {
            var interaction = P15.interaction()
            if ending == .ownerPassed { try interaction.apply(.ownerNeeded(P15.question(1)), at: P15.now) }
            if ending == .planEnded {
                try interaction.apply(.proposalReady(P15.proposal(1)), at: P15.now)
                try interaction.apply(.ownerAccepted(revision: 1), at: P15.now)
                try interaction.apply(.everyoneConfirmed(revision: 1), at: P15.now)
            }
            try interaction.apply(ending, at: P15.now)
            interaction = try P15.restart(interaction)
            #expect(interaction.state.isFinal)
            for event in attacks {
                let snapshot = interaction
                #expect(throws: (any Error).self) { try interaction.apply(event, at: P15.now) }
                #expect(interaction == snapshot, "Late \(event) after \(ending)")
            }
        }
    }

    /// A fallback transcript tests the shared lifecycle contract, not an OS
    /// permission implementation. Real adapters are tracked in the scenario matrix.
    @Test(arguments: [SampleSkills.findATime, SampleSkills.pickAPlace, SampleSkills.swapPhotos])
    func scriptedDeniedPermissionTranscriptSurvivesRestart(skill: SkillDescriptor) async throws {
        var interaction = P15.interaction(skill)
        let service = ScriptedSkillService(descriptor: skill)
        let issue: IssueKey = skill.id == .pickAPlace ? .place : skill.id == .swapPhotos ? .photos : .time
        let question = try P15.question(1, issue: issue)
        let events: [InteractionEvent] = skill.id == .swapPhotos ? [.ownerPassed] : [
            .ownerAnswered(question: 1), .proposalReady(try P15.proposal(1)),
            .ownerAccepted(revision: 1), .everyoneConfirmed(revision: 1),
        ]
        // Denied photos stays off; calendar/location denial asks the owner.
        try interaction.apply(.ownerNeeded(question), at: P15.now)
        interaction = try P15.restart(interaction)
        let store = InMemoryInteractionStore([interaction])
        try await service.restore(store.all())
        for event in events { await service.emit(.lifecycle(interaction.id, event)) }
        await service.shutdown()
        for await event in service.events {
            guard case .lifecycle(let id, let lifecycle) = event else { Issue.record("Unexpected event"); continue }
            #expect(id == interaction.id)
            try interaction.apply(lifecycle, at: P15.now)
            try await store.save(interaction)
        }
        #expect(interaction.state == (skill.id == .swapPhotos ? .ended(.declined) : .planned))
        #expect(interaction.egress.isEmpty)
        #expect(await service.started.isEmpty)
    }
}
