import Foundation
import StarlingCore
import StarlingFakes
import StarlingPolicy
import Testing

@Suite struct ContextTests {
    @Test func answerUsesItsOwnIssueWithoutQueryRegistration() async throws {
        let engine = DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty, disclosure: [
            DisclosureRule(issue: .diet, action: .never),
        ]))
        let body = MessageBody.answer(try Answer(query: MessageID(), issue: .diet, status: .answered, acceptable: Fixtures.value))
        let message = try Fixtures.outbound(body)
        #expect(try engine.disclosure(for: message).items == [DisclosedItem(category: .terms, issue: .diet, value: Fixtures.value)])
        #expect(await engine.evaluate(message) == .deny(PolicyViolation(rule: PolicyRuleID.never, issue: .diet)))
    }

    @Test func psiContextIsRequiredForEverySendAndDoesNotPersist() async throws {
        let engine = Fixtures.engine(action: .allowOnDevicePeers)
        let body = try Fixtures.body(.psi)
        let missing = try Fixtures.outbound(body)
        let expected = PolicyDecision.deny(PolicyViolation(rule: PolicyRuleID.missingPSIContext))
        #expect(await engine.evaluate(missing) == expected)
        let supplied = try Fixtures.outbound(body, context: Fixtures.psiContext())
        #expect(await engine.evaluate(supplied) == .needsConsent(try engine.disclosure(for: supplied)))
        #expect(await engine.evaluate(missing) == expected)
    }

    @Test(arguments: [DisclosureRule.Action.never, .askEachTime, .allowOnDevicePeers])
    func privatePSIStillHonorsIssueRules(action: DisclosureRule.Action) async throws {
        let engine = Fixtures.engine(action: action)
        let message = try Fixtures.outbound(Fixtures.body(.psi), context: Fixtures.psiContext(privatePSI: true))
        let disclosure = try engine.disclosure(for: message)
        #expect(disclosure.items == [DisclosedItem(category: .psi, issue: .activity, value: nil)])
        let expected: PolicyDecision = switch action {
        case .never: .deny(PolicyViolation(rule: PolicyRuleID.never, issue: .activity))
        case .askEachTime: .needsConsent(disclosure)
        case .allowOnDevicePeers: .allow
        }
        #expect(await engine.evaluate(message) == expected)
    }

    @Test(arguments: [false, true])
    func emptyPSIInputsStillRequireConsent(isPrivate: Bool) async throws {
        let engine = Fixtures.engine(action: .allowOnDevicePeers)
        for step in [UInt8(0), 1, 255] {
            let frame = try PSIFrame(session: UUID(), step: step, payload: Data())
            let message = try Fixtures.outbound(.psi(frame), context: Fixtures.psiContext(privatePSI: isPrivate, inputs: [:]))
            #expect(await engine.evaluate(message) == .needsConsent(try engine.disclosure(for: message)))
        }
    }

    @Test func nonPrivatePSIDisclosesAllInputsAndNeverWins() async throws {
        let inputs: [IssueKey: IssueValue] = [
            .activity: Fixtures.value,
            .time: .slots([try TimeSlot(startMinute: 100, endMinute: 200)]),
            .budget: .amount(try MoneyAmount(minorUnits: 1575)),
        ]
        let message = try Fixtures.outbound(Fixtures.body(.psi), context: Fixtures.psiContext(inputs: inputs))
        let engine = Fixtures.engine(action: .allowOnDevicePeers)
        let disclosure = try engine.disclosure(for: message)
        #expect(disclosure.items == inputs.keys.sorted().map { DisclosedItem(category: .psi, issue: $0, value: inputs[$0]) })
        #expect(await engine.evaluate(message) == .needsConsent(disclosure))
        #expect(await Fixtures.engine(action: .never).evaluate(message) == .deny(PolicyViolation(rule: PolicyRuleID.never, issue: .activity)))
    }

    @Test func unrelatedPSIContextDoesNotChangeAnAnswer() async throws {
        let engine = Fixtures.engine(action: .never)
        let message = try Fixtures.outbound(Fixtures.body(.answer), context: Fixtures.psiContext(privatePSI: true, inputs: [.budget: .count(0)]))
        #expect(try engine.disclosure(for: message).items == [DisclosedItem(category: .interest, issue: .activity, value: Fixtures.value)])
        #expect(await engine.evaluate(message) == .deny(PolicyViolation(rule: PolicyRuleID.never, issue: .activity)))
    }

    @Test(arguments: [false, true])
    func invalidTypedPSIInputsAreDenied(isPrivate: Bool) async throws {
        let message = try Fixtures.outbound(Fixtures.body(.psi), context: Fixtures.psiContext(privatePSI: isPrivate, inputs: [.partySize: .count(-1)]))
        #expect(await Fixtures.engine().evaluate(message) == .deny(PolicyViolation(rule: PolicyRuleID.invalidPSIContext, issue: .partySize)))
    }

    @Test func missingAndFailingPairingStoreCannotAutomaticallyShare() async throws {
        let rules = OwnerRules(constraints: .empty, disclosure: [DisclosureRule(issue: .activity, action: .allowOnDevicePeers)])
        let absent = DeterministicPolicyEngine(ownerRules: rules)
        let broken = DeterministicPolicyEngine(ownerRules: rules, pairedPeers: BrokenPeerStore())
        let message = try Fixtures.outbound(Fixtures.body(.query))
        #expect(await absent.evaluate(message) == .needsConsent(try absent.disclosure(for: message)))
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
            let context = OutboundContext(psi: .init(provider: provider.descriptor, inputs: Fixtures.terms.values))
            let message = try Fixtures.outbound(.psi(frame), context: context)
            let disclosure = try engine.disclosure(for: message)
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
