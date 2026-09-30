import Foundation
import StarlingCore
import StarlingFakes
import StarlingPolicy
import Testing

@Suite struct ContextTests {
    @Test func answerRequiresExactQueryScopeAndNeverCannotBeBypassed() async throws {
        let engine = Fixtures.engine(action: .never)
        let body = try Fixtures.body(.answer)
        let message = try Fixtures.outbound(body)
        #expect(await engine.evaluate(message) == .deny(PolicyViolation(rule: PolicyRuleID.missingQueryContext)))
        try await Fixtures.registerContext(engine)
        #expect(await engine.evaluate(message) == .deny(PolicyViolation(rule: PolicyRuleID.never, issue: .activity)))
        for changed in [
            try Fixtures.outbound(body, recipient: .random()),
            try Fixtures.outbound(body, conversation: ConversationID()),
            OutboundMessage(envelope: try Fixtures.envelope(body, sender: .random()), recipientCard: Fixtures.card, transport: .loopback),
            try Fixtures.outbound(.answer(Answer(query: MessageID(), status: .answered, acceptable: Fixtures.value))),
        ] {
            #expect(await engine.evaluate(changed) == .deny(PolicyViolation(rule: PolicyRuleID.missingQueryContext)))
        }
        await engine.forgetConversation(Fixtures.conversation, with: Fixtures.bob.id)
        #expect(await engine.evaluate(message) == .deny(PolicyViolation(rule: PolicyRuleID.missingQueryContext)))
    }

    @Test func answerIssueIsNotInferredFromValueShape() async throws {
        let engine = DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty, disclosure: [
            DisclosureRule(issue: .diet, action: .never),
        ]))
        try await engine.registerReceivedQuery(Fixtures.envelope(
            .query(Query(issue: .diet, candidates: Fixtures.value)),
            sender: Fixtures.bob.id, recipient: Fixtures.alice, id: Fixtures.queryID
        ))
        let message = try Fixtures.outbound(Fixtures.body(.answer))
        #expect(try await engine.disclosure(for: message).items.first?.issue == .diet)
        #expect(await engine.evaluate(message) == .deny(PolicyViolation(rule: PolicyRuleID.never, issue: .diet)))
    }

    @Test func psiContextIsBoundToFramePeerAndConversation() async throws {
        let engine = Fixtures.engine(action: .allowOnDevicePeers)
        let message = try Fixtures.outbound(Fixtures.body(.psi))
        #expect(await engine.evaluate(message) == .deny(PolicyViolation(rule: PolicyRuleID.missingPSIContext)))
        try await Fixtures.registerContext(engine)
        for changed in [
            try Fixtures.outbound(Fixtures.body(.psi), recipient: .random()),
            try Fixtures.outbound(Fixtures.body(.psi), conversation: ConversationID()),
            try Fixtures.outbound(.psi(PSIFrame(session: Fixtures.frame.session, step: 1, payload: Fixtures.frame.payload))),
            try Fixtures.outbound(.psi(PSIFrame(session: Fixtures.frame.session, step: 0, payload: Data([9])))),
            try Fixtures.outbound(.psi(PSIFrame(session: UUID(), step: 0, payload: Fixtures.frame.payload))),
        ] {
            #expect(await engine.evaluate(changed) == .deny(PolicyViolation(rule: PolicyRuleID.missingPSIContext)))
        }
        await engine.forgetConversation(Fixtures.conversation, with: Fixtures.bob.id)
        #expect(await engine.evaluate(message) == .deny(PolicyViolation(rule: PolicyRuleID.missingPSIContext)))
    }

    @Test(arguments: [DisclosureRule.Action.never, .askEachTime, .allowOnDevicePeers])
    func privatePSIStillHonorsIssueRules(action: DisclosureRule.Action) async throws {
        let engine = Fixtures.engine(action: action)
        try await Fixtures.registerContext(engine, privatePSI: true)
        let message = try Fixtures.outbound(Fixtures.body(.psi))
        let disclosure = try await engine.disclosure(for: message)
        #expect(disclosure.items == [DisclosedItem(category: .psi, issue: .activity, value: nil)])
        let expected: PolicyDecision = switch action {
        case .never: .deny(PolicyViolation(rule: PolicyRuleID.never, issue: .activity))
        case .askEachTime: .needsConsent(disclosure)
        case .allowOnDevicePeers: .allow
        }
        #expect(await engine.evaluate(message) == expected)
    }

    @Test(arguments: [false, true])
    func everyPSIStepIncludingEmptyInputsRequiresConsentWhenNotPrivate(isPrivate: Bool) async throws {
        let engine = Fixtures.engine(action: .allowOnDevicePeers)
        for step in [UInt8(0), 1, 255] {
            let frame = try PSIFrame(session: UUID(), step: step, payload: Data())
            try await engine.registerPSIStep(frame, to: Fixtures.bob.id, conversation: Fixtures.conversation,
                                            provider: PSIProviderDescriptor(name: "test", isPrivate: isPrivate), inputs: .empty)
            let message = try Fixtures.outbound(.psi(frame))
            #expect(await engine.evaluate(message) == .needsConsent(try await engine.disclosure(for: message)))
        }
    }

    @Test func contextRegistrationCannotOverwriteProtectedIssueOrProvider() async throws {
        let engine = Fixtures.engine()
        try await Fixtures.registerContext(engine)
        try await Fixtures.registerContext(engine)
        await #expect(throws: PolicyContextError.conflictingRegistration) {
            try await engine.registerReceivedQuery(Fixtures.envelope(
                .query(Query(issue: .place, candidates: Fixtures.value)),
                sender: Fixtures.bob.id, recipient: Fixtures.alice, id: Fixtures.queryID
            ))
        }
        await #expect(throws: PolicyContextError.conflictingRegistration) {
            try await engine.registerPSIStep(Fixtures.frame, to: Fixtures.bob.id, conversation: Fixtures.conversation,
                                            provider: PSIProviderDescriptor(name: "private", isPrivate: true), inputs: Fixtures.terms)
        }
        await #expect(throws: PolicyContextError.notAQuery) {
            try await engine.registerReceivedQuery(Fixtures.envelope(Fixtures.body(.hello)))
        }
    }

    @Test func boundedContextDoesNotEvictLiveRulesAndCanBeReleased() async throws {
        let engine = Fixtures.engine()
        for _ in 0..<DeterministicPolicyEngine.maxContextEntries {
            try await engine.registerReceivedQuery(Fixtures.envelope(
                .query(Query(issue: .place, candidates: Fixtures.value)), sender: Fixtures.bob.id, recipient: Fixtures.alice
            ))
        }
        await #expect(throws: PolicyContextError.capacityExceeded) {
            try await engine.registerPSIStep(Fixtures.frame, to: Fixtures.bob.id, conversation: Fixtures.conversation,
                                            provider: Fixtures.stub, inputs: Fixtures.terms)
        }
        await engine.forgetConversation(Fixtures.conversation, with: Fixtures.bob.id)
        try await Fixtures.registerContext(engine)
    }

    @Test func missingAndFailingPairingStoreCannotAutomaticallyShare() async throws {
        let rules = OwnerRules(constraints: .empty, disclosure: [DisclosureRule(issue: .activity, action: .allowOnDevicePeers)])
        let absent = DeterministicPolicyEngine(ownerRules: rules)
        let broken = DeterministicPolicyEngine(ownerRules: rules, pairedPeers: BrokenPeerStore())
        let message = try Fixtures.outbound(Fixtures.body(.query))
        #expect(await absent.evaluate(message) == .needsConsent(try await absent.disclosure(for: message)))
        #expect(await broken.evaluate(message) == .deny(PolicyViolation(rule: PolicyRuleID.pairedStoreUnavailable)))
    }

    @Test func actualInsecureProviderRequiresConsentForRequestAndReply() async throws {
        let provider = InsecurePSIStub()
        let configuration = try PSIConfiguration(output: .intersection, maxPeerSetSize: 2, maxLocalSetSize: 2)
        let elements: Set<PSIElement> = [try PSIElement(Data("boba".utf8))]
        let initiator = try provider.makeSession(role: .initiator, localSet: elements, configuration: configuration)
        let responder = try provider.makeSession(role: .responder, localSet: elements, configuration: configuration)
        guard case .send(let request) = try await initiator.start() else {
            Issue.record("Expected a PSI request")
            return
        }
        guard case .finish(let reply?, _) = try await responder.handle(request) else {
            Issue.record("Expected a PSI reply")
            return
        }
        let engine = Fixtures.engine(action: .allowOnDevicePeers)
        let session = UUID()
        for (index, payload) in [request, reply].enumerated() {
            let frame = try PSIFrame(session: session, step: UInt8(index), payload: payload)
            try await engine.registerPSIStep(frame, to: Fixtures.bob.id, conversation: Fixtures.conversation,
                                            provider: provider.descriptor, inputs: Fixtures.terms)
            let message = try Fixtures.outbound(.psi(frame))
            let disclosure = try await engine.disclosure(for: message)
            #expect(disclosure.items == [DisclosedItem(category: .psi, issue: .activity, value: Fixtures.value)])
            #expect(await engine.evaluate(message) == .needsConsent(disclosure))
        }
    }
}

private struct BrokenPeerStore: PairedPeerStore {
    struct Unavailable: Error {}
    func all() async throws -> [PairedPeer] { throw Unavailable() }
    func peer(for id: PeerID) async throws -> PairedPeer? { throw Unavailable() }
    func save(_ peer: PairedPeer) async throws { throw Unavailable() }
    func remove(_ id: PeerID) async throws { throw Unavailable() }
}
