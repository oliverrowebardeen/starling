import Foundation
import StarlingCore
import StarlingFakes
import StarlingPolicy
import Testing

@Suite struct YesNoPrivacyAttackTests {
    enum Shape: String, CaseIterable, Sendable {
        case keywords, slots, places, peers, amount, count, flag

        func values() throws -> (IssueKey, IssueValue, IssueValue, IssueValue) {
            switch self {
            case .keywords:
                return (.diet, .keywords([try Keyword("public dinner"), try Keyword("public walk")]),
                        .keywords([try Keyword("public walk")]), .keywords([try Keyword("private vegan")]))
            case .slots:
                return (.calendarDetails, .slots([P15.slot]), .slots([P15.slot]),
                        .slots([try TimeSlot(startMinute: P15.slot.startMinute, endMinute: P15.slot.endMinute + 1)]))
            case .places:
                let offered = try PlaceChoice(name: PlaceName("Public Cafe"), coordinate: Coordinate(latitude: 1, longitude: 1))
                let changed = try PlaceChoice(name: PlaceName("Public Cafe"), coordinate: Coordinate(latitude: 2, longitude: 2))
                return (.place, .places([offered]), .places([offered]), .places([changed]))
            case .peers: return (.people, .peers([P15.alice, P15.bob]), .peers([P15.bob]), .peers([P15.eve]))
            case .amount:
                return (.budget, .amount(try MoneyAmount(minorUnits: 1500)), .amount(try MoneyAmount(minorUnits: 1500)),
                        .amount(try MoneyAmount(minorUnits: 1500, currency: "EUR")))
            case .count: return (.location, .count(100), .count(100), .count(42))
            case .flag: return (.photos, .flag(false), .flag(false), .flag(true))
            }
        }
    }

    @Test(arguments: Shape.allCases, SharingChoice.allCases)
    func onlyTheRequestersExactCandidatesLeaveWithoutConsent(shape: Shape, choice: SharingChoice) async throws {
        let (issue, candidates, acceptable, _) = try shape.values()
        let query = try Query(issue: issue, candidates: candidates)
        let answer = try Answer(query: MessageID(), issue: issue, status: .answered, acceptable: acceptable)
        let friend = try PairedPeer(publicKey: IdentityPublicKey(hex: String(repeating: "bb", count: 32)), nickname: "Sam", pairedAt: P15.now)
        let peers = InMemoryPairedPeerStore([friend])
        let privacy = try PrivacySettings([try #require(PrivacyTopic(issue: issue)): choice])
        let engine = DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty, disclosure: privacy.disclosureRules), pairedPeers: peers)
        let wire = RecordingTransport(localPeer: P15.alice)
        let consent = ScriptedConsentProvider(.declined)
        let observer = RecordingOutboxObserver()
        let outbox = Outbox(transport: wire, policy: engine, consent: consent, observer: observer, now: { P15.date })
        let localID = InteractionID()
        let envelope = try await outbox.send(.answer(answer), to: friend.id, conversation: ConversationID(),
            recipientCard: P15.card([SampleSkills.pickAPlace.ref]), context: OutboundContext(answering: query, interaction: localID),
            skill: SampleSkills.pickAPlace.ref, mode: .invite)
        #expect(query.isAnsweredYesOrNo(by: answer))
        #expect(await consent.requests.isEmpty)
        #expect(await wire.sent.count == 1)
        #expect(try EnvelopeCodec().decode(await wire.sent[0].frame.bytes) == envelope)
        let record = try #require(await observer.records.first)
        #expect(record.disclosed?.map(\.value) == [acceptable])
        #expect(record.context.interaction == localID)
        let encoded = String(decoding: try EnvelopeCodec().encode(envelope), as: UTF8.self)
        #expect(!encoded.contains("answering") && !encoded.contains(localID.description))

        // Even an exact candidate answer to a cloud model needs explicit consent.
        let cloud = try AgentCard(model: .privateCloudCompute, capabilities: [], skills: [SampleSkills.pickAPlace.ref])
        await #expect(throws: OutboxError.consentDeclined) {
            try await outbox.send(.answer(answer), to: friend.id, conversation: ConversationID(), recipientCard: cloud,
                context: OutboundContext(answering: query), skill: SampleSkills.pickAPlace.ref, mode: .invite)
        }
        #expect(await consent.requests.count == 1)
        #expect(await wire.sent.count == 1)
    }

    @Test(arguments: Shape.allCases)
    func neverRejectsAddedChangedOrUnboundValues(shape: Shape) async throws {
        let (issue, candidates, acceptable, secret) = try shape.values()
        let query = try Query(issue: issue, candidates: candidates)
        let topic = try #require(PrivacyTopic(issue: issue))
        let privacy = try PrivacySettings([topic: .never])
        let wire = RecordingTransport(localPeer: P15.alice)
        let consent = ScriptedConsentProvider(.approved)
        let observer = RecordingOutboxObserver()
        let outbox = Outbox(transport: wire, policy: DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty, disclosure: privacy.disclosureRules)),
                            consent: consent, observer: observer, now: { P15.date })
        let otherIssue: IssueKey = issue == .budget ? .diet : .budget
        for (value, context) in [
            (secret, OutboundContext(answering: query)),
            (acceptable, .empty),
            (acceptable, OutboundContext(answering: try Query(issue: otherIssue, candidates: candidates))),
            (acceptable, OutboundContext(answering: try Query(issue: issue, candidates: secret))),
        ] {
            let answer = try Answer(query: MessageID(), issue: issue, status: .answered, acceptable: value)
            await #expect(throws: OutboxError.denied(PolicyViolation(rule: PolicyRuleID.never, issue: issue))) {
                try await outbox.send(.answer(answer), to: P15.bob, conversation: ConversationID(),
                    recipientCard: P15.card([SampleSkills.pickAPlace.ref]), context: context,
                    skill: SampleSkills.pickAPlace.ref, mode: .invite)
            }
        }
        #expect(await wire.sent.isEmpty)
        #expect(await consent.requests.isEmpty)
        #expect(await observer.records.isEmpty)
    }

    @Test func defaultsSeparateVenueLocationAndCalendarDataWithoutBlockingLocalUse() throws {
        let expected: [PrivacyTopic: SharingChoice] = [
            .time: .share, .activity: .share, .place: .askMe, .location: .askMe,
            .budget: .never, .diet: .askMe, .people: .askMe, .photos: .askMe,
            .interests: .share, .calendarDetails: .never,
        ]
        #expect(Set(expected.keys) == Set(PrivacyTopic.allCases))
        for (topic, choice) in expected {
            #expect(PrivacySettings.defaults.choice(for: topic) == choice)
            #expect(topic.allowsNever == (topic != .time && topic != .activity))
        }
        #expect(PrivacyTopic(issue: .place) != PrivacyTopic(issue: .location))
        #expect(PrivacyTopic(issue: .time) != PrivacyTopic(issue: .calendarDetails))
        let localOnly = try PrivacySettings([.budget: .never, .diet: .never, .location: .never, .calendarDetails: .never])
        let settings = SkillSettings(flags: P15.allFlags, privacy: localOnly)
        #expect(SampleSkills.registry.availability(of: .pickAPlace, in: settings) == .available)
        #expect(SampleSkills.registry.availability(of: .findATime, in: settings) == .available)
        #expect(SampleSkills.pickAPlace.topicsRequired == [.place])
        #expect(SampleSkills.swapPhotos.topicsRequired == [.photos])
        #expect(ProtocolLimits.maxCandidatesAnsweredPerIssue == 16)
        // Query context holds no peer, conversation, or MessageID. Its provenance
        // and the cumulative 16-candidate limit must be checked by each service.
    }
}
