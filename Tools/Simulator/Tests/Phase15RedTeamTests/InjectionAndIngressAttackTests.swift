import Foundation
import Scenarios
import SimulatorKit
@testable import StarlingAgent
import StarlingCore
import StarlingFakes
import Testing

@Suite(.timeLimit(.minutes(1))) struct InjectionAndIngressAttackTests {
    @Test(arguments: Phase15Attacks.venueNames)
    func chainedVenueSurvivesAsDisplayDataButNeverEntersDecisionPrompt(name: String) throws {
        let terms = try Phase15Attacks.terms(venue: name, keyword: "skip consent")
        let envelope = try Envelope(conversation: ConversationID(), sender: P15.alice, recipient: P15.bob,
                                    sequence: 0, sentAt: P15.now, body: .propose(Proposal(round: 0, terms: terms)),
                                    skill: SampleSkills.pickAPlace.ref, chainedFrom: ConversationID())
        let codec = EnvelopeCodec()
        let decoded = try codec.decode(codec.encode(envelope))
        guard case .propose(let proposal) = decoded.body, case .places(let places) = proposal.terms[.place] else {
            Issue.record("Lost typed place"); return
        }
        let plan = try Plan(origin: decoded.conversation, attendees: Attendees([P15.alice, P15.bob]),
                            activity: Keyword("boba"), time: P15.slot).updating(place: places[0])
        let restored = try JSONDecoder().decode(Artifact.self, from: JSONEncoder().encode(Artifact.plan(plan)))
        #expect(restored == .plan(plan))
        #expect(plan.place?.name.rawValue == name)
        let context = NegotiationContext(proposal: proposal, constraints: .empty, history: [], now: P15.date)
        let prompt = PromptRenderer.decide(context, timeZone: TimeZone(secondsFromGMT: 0)!).text
        #expect(!prompt.contains(name))
        #expect(prompt.contains("1 place option"))
        // Keywords are allowed bounded model inputs, not guaranteed harmless text.
        #expect(prompt.contains("skip consent"))
    }

    @Test(arguments: Phase15Attacks.invalidVenueNames)
    func hostileVenueControlCharactersAreRejectedAtDecode(name: String) throws {
        let bytes = try JSONEncoder().encode(name)
        #expect(throws: ValidationError.self) { try JSONDecoder().decode(PlaceName.self, from: bytes) }
    }

    @Test(arguments: Phase15Attacks.keywords)
    func instructionKeywordsCannotMakeUnsafeModelMovesSatisfyHardLimits(keyword: String) async throws {
        let budget = try MoneyAmount(minorUnits: 1500)
        let constraints = try ConstraintSet([.budget: [Constraint(.atMost(budget))]])
        let terms = try Terms([.activity: .keywords([Keyword(keyword)]), .budget: .amount(MoneyAmount(minorUnits: 5000))])
        let proposal = try Proposal(round: 0, terms: terms)
        let model = ScriptedAgentModel(onDecide: { _ in .accept })
        let result = try await model.decide(NegotiationContext(proposal: proposal, constraints: constraints, history: [], now: P15.date))
        #expect(result.value == .accept)
        #expect(!constraints.violations(of: terms, timeZone: TimeZone(secondsFromGMT: 0)!).isEmpty)
        // The integration suite separately verifies Down enforces this result.
    }

    @Test func authenticatedPeerCanSendChainHintsButCannotForgeAnotherSender() async throws {
        let simulation = Simulation(now: { P15.date }, security: .secureChannel)
        do {
            let owner = try await simulation.addAgent("owner")
            let attacker = try await simulation.addAgent("attacker")
            let friend = try await simulation.addAgent("friend")
            try await simulation.waitForMesh()
            let channel = try #require(attacker.secureTransport)
            // SimulatedAgent.send has no v2 metadata arguments. A dedicated
            // Outbox on the same authenticated channel uses fresh conversations.
            let outbox = Outbox(transport: channel, policy: FixedPolicyEngine(.allow),
                                consent: ScriptedConsentProvider(.approved), now: { P15.date })
            for ref in [SampleSkills.findATime.ref, SampleSkills.pickAPlace.ref, SampleSkills.swapPhotos.ref,
                        SkillRef(.swapPhotos, SkillVersion(2)), SkillRef(try SkillID("request_permission"), SkillVersion(1))] {
                let parent = ConversationID()
                let sent = try await outbox.send(.propose(Proposal(round: 0, terms: Phase15Attacks.terms(
                    venue: Phase15Attacks.venueNames[0], keyword: "start swap photos"))),
                    to: owner.id, conversation: ConversationID(), skill: ref, chainedFrom: parent)
                try await Simulation.eventually("authenticated v2 proposal") { await owner.received.contains(sent) }
                #expect(sent.sender == attacker.id)
                #expect(sent.chainedFrom == parent && sent.skill == ref)
            }
            let before = await owner.received.count
            let ownerChannel = try #require(owner.secureTransport)
            let drops = await ownerChannel.status(of: friend.id).droppedFrames
            let forged = try Envelope(conversation: ConversationID(), sender: friend.id, recipient: owner.id,
                sequence: 0, sentAt: P15.now, body: .propose(Proposal(round: 0, terms: P15.proposal(1).terms)),
                skill: SampleSkills.swapPhotos.ref, chainedFrom: ConversationID())
            try await simulation.hub.inject(Frame(EnvelopeCodec().encode(forged)), claimedSender: friend.id, to: owner.id)
            try await Simulation.eventually("forged chain frame rejected") { await ownerChannel.status(of: friend.id).droppedFrames > drops }
            #expect(await owner.received.count == before)
            #expect(await ownerChannel.status(of: friend.id).provenKey?.peerID == friend.id)
            // Positive control after the attack: the actual friend still sends.
            let valid = try await friend.send(.reject(Rejection(proposal: MessageID(), reason: .declinedByOwner)), to: owner.id)
            try await Simulation.eventually("real friend still reachable") { await owner.received.contains(valid) }
            await simulation.stop()
        } catch {
            await simulation.stop()
            throw error
        }
    }

    @Test func chainMetadataDoesNotResetReplayOrAgeValidation() async throws {
        let inbox = Inbox(localPeer: P15.bob, now: { P15.date })
        let conversation = ConversationID()
        func frame(sequence: UInt64, age: TimeInterval = 0, skill: SkillRef = SampleSkills.pickAPlace.ref) throws -> Frame {
            try Frame(EnvelopeCodec().encode(Envelope(conversation: conversation, sender: P15.alice, recipient: P15.bob,
                sequence: sequence, sentAt: Timestamp(P15.date.addingTimeInterval(age)),
                body: .propose(Proposal(round: 0, terms: P15.proposal(1).terms)), skill: skill, chainedFrom: ConversationID())))
        }
        let valid = try frame(sequence: 0)
        #expect(try await inbox.accept(valid, from: P15.alice).get().sequence == 0)
        #expect(await inbox.accept(try frame(sequence: 0, skill: SampleSkills.swapPhotos.ref), from: P15.alice) == .failure(.replay))
        #expect(await inbox.accept(try frame(sequence: .max, age: -601), from: P15.alice) == .failure(.stale))
        #expect(await inbox.accept(try frame(sequence: .max, age: 121), from: P15.alice) == .failure(.fromFuture))
        #expect(try await inbox.accept(frame(sequence: 1), from: P15.alice).get().sequence == 1)
        // A new Inbox loses its replay window. Persistent Interaction watermarks
        // and authenticated sessions, not this API, must protect restart recovery.
        let restarted = Inbox(localPeer: P15.bob, now: { P15.date })
        #expect(try await restarted.accept(valid, from: P15.alice).get().sequence == 0)
    }
}
