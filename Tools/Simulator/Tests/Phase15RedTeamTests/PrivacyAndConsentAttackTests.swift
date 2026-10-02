import Foundation
import SimulatorKit
import StarlingCore
import StarlingFakes
import StarlingFeatures
import StarlingPolicy
import Testing

@Suite(.timeLimit(.minutes(5))) struct PrivacyAndConsentAttackTests {
    @Test(arguments: SampleSkills.all, PrivacyTopic.allCases.filter(\.allowsNever))
    func neverBlocksEverySkillAndEveryTypedEgressShape(skill: SkillDescriptor, topic: PrivacyTopic) async throws {
        let privacy = try PrivacySettings([topic: .never])
        let rules = OwnerRules(constraints: .empty, disclosure: privacy.disclosureRules)
        let transport = RecordingTransport(localPeer: P15.alice)
        let consent = ScriptedConsentProvider(.approved)
        let observer = RecordingOutboxObserver()
        let outbox = Outbox(transport: transport, policy: DeterministicPolicyEngine(ownerRules: rules),
                            consent: consent, observer: observer, now: { P15.date })
        let allowed = Outbox(transport: transport, policy: DeterministicPolicyEngine(),
                             consent: consent, observer: observer, now: { P15.date })
        var sent = 0
        for issue in topic.issues.sorted() {
            let value = try P15.value(issue)
            for body in try P15.bodies(issue: issue, value: value) {
                let denied = OutboxError.denied(PolicyViolation(rule: PolicyRuleID.never, issue: issue))
                await #expect(throws: denied) {
                    try await outbox.send(body, to: P15.bob, conversation: ConversationID(),
                                          recipientCard: P15.card([skill.ref]), skill: skill.ref, mode: skill.defaultSendMode,
                                          chainedFrom: ConversationID())
                }
                #expect(await transport.sent.count == sent)
                #expect(await observer.records.count == sent)
                #expect(await consent.requests.count == sent)
                // Positive control: the identical payload can pass when the owner allows it.
                try await allowed.send(body, to: P15.bob, conversation: ConversationID(),
                                       recipientCard: P15.card([skill.ref]), skill: skill.ref, mode: skill.defaultSendMode)
                sent += 1
            }
        }
        #expect(await transport.sent.count == sent)
    }

    @Test(arguments: PrivacyTopic.allCases.filter(\.allowsNever))
    func privacyChoicesChangeLocalAvailabilityButNeverTheWireCard(topic: PrivacyTopic) throws {
        let registry = SampleSkills.registry
        let original = SkillSettings(flags: P15.allFlags)
        let locked = SkillSettings(flags: P15.allFlags, privacy: try PrivacySettings([topic: .never]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(P15.card(registry.advertised(in: original))) == encoder.encode(P15.card(registry.advertised(in: locked))))
        for skill in SampleSkills.all {
            let blocked = skill.topicsRequired.intersection([topic])
            #expect(registry.availability(of: skill.id, in: locked) == (blocked.isEmpty ? .available : .blockedByPrivacy(blocked)))
            if !blocked.isEmpty {
                #expect(!registry.available(in: locked).contains(skill))
                #expect(registry.advertised(in: locked).contains(skill.ref))
            }
        }
    }

    @Test func chainExposureNeverTreatsTopicsAsPermissionGrants() {
        let places = SampleSkills.pickAPlace.exposure
        let onlyTopics = SkillExposure(topics: places.topics)
        #expect(places.adding(over: onlyTopics).permissions == [.locationWhenInUse])
        #expect(places.adding(over: SampleSkills.downFor.exposure).topics == [.diet, .location])
        #expect(places.adding(over: SampleSkills.downFor.exposure).permissions == [.locationWhenInUse])
        let photos = SampleSkills.swapPhotos.exposure.adding(over: SampleSkills.downFor.exposure.union(places))
        #expect(photos.topics == [.photos] && photos.permissions == [.photoLibrary])
        #expect(SampleSkills.swapPhotos.chainTrigger == .afterPlanEnds)
        #expect(SampleSkills.registry.availability(of: .swapPhotos, in: SkillSettings(flags: .phase1_5)) == .notInThisBuild)
    }

    @MainActor @Test func approvalMemoryCannotCrossAChainOrSkillAndOldSheetCannotApproveNewOne() async throws {
        let consent = ConsentCoordinator(peers: nil, timeout: .seconds(180), now: { P15.date })
        let transport = RecordingTransport(localPeer: P15.alice)
        let observer = RecordingOutboxObserver()
        let outbox = Outbox(transport: transport, policy: DeterministicPolicyEngine(), consent: consent,
                            observer: observer, now: { P15.date })
        let body = try P15.bodies(issue: .people, value: .peers([P15.alice, P15.bob]))[0]
        let root = ConversationID()
        func send(_ conversation: ConversationID, _ skill: SkillRef, parent: ConversationID? = nil, localID: InteractionID? = nil) -> Task<Envelope, any Error> {
            Task { try await outbox.send(body, to: P15.bob, conversation: conversation,
                                         recipientCard: P15.card(SampleSkills.all.map(\.ref)), context: OutboundContext(interaction: localID),
                                         skill: skill, mode: .invite, chainedFrom: parent) }
        }
        let first = send(root, SampleSkills.downFor.ref)
        defer { first.cancel() }
        try await P15.eventually("initial consent") { consent.current != nil }
        let firstSheet = try #require(consent.current)
        consent.answer(.approved, to: firstSheet.id)
        _ = try await first.value
        // An exact retry inside the same interaction may use the approval.
        _ = try await send(root, SampleSkills.downFor.ref).value
        #expect(consent.current == nil)
        #expect(await transport.sent.count == 2)
        for (conversation, skill, parent, localID) in [
            (ConversationID(), SampleSkills.downFor.ref, Optional(root), Optional<InteractionID>.none),
            (root, SampleSkills.pickAPlace.ref, nil, nil),
            (root, SampleSkills.downFor.ref, nil, InteractionID()),
        ] {
            let next = send(conversation, skill, parent: parent, localID: localID)
            defer { next.cancel() }
            try await P15.eventually("fresh consent for changed scope") { consent.current != nil }
            let sheet = try #require(consent.current)
            #expect(sheet.disclosure.conversation == conversation && sheet.disclosure.skill == skill)
            #expect(sheet.disclosure.interaction == localID)
            #expect(sheet.disclosure.items == firstSheet.disclosure.items)
            consent.answer(.approved, to: firstSheet.id)
            #expect(consent.current?.id == sheet.id)
            #expect(await transport.sent.count == 2)
            consent.answer(.declined, to: sheet.id)
            await #expect(throws: OutboxError.consentDeclined) { try await next.value }
        }
        #expect(await observer.records.count == 2)
    }
}
