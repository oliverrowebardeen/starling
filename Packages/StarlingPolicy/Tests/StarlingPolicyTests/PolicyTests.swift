import Foundation
import StarlingCore
import StarlingFakes
import StarlingPolicy
import Testing

@Suite struct PolicyTests {
    @Test(arguments: MessageBody.Kind.allCases,
          [DisclosureRule.Action.never, .askEachTime, .allowOnDevicePeers])
    func everyBodyAndRule(kind: MessageBody.Kind, action: DisclosureRule.Action) async throws {
        let engine = Fixtures.engine(action: action)
        let message = try Fixtures.outbound(Fixtures.body(kind), context: kind == .psi ? Fixtures.psiContext() : .empty)
        let disclosure = try engine.disclosure(for: message)
        let decision = await engine.evaluate(message)
        if kind == .hello || kind == .reject {
            #expect(decision == .allow)
        } else if action == .never {
            #expect(decision == .deny(PolicyViolation(rule: PolicyRuleID.never, issue: .activity)))
        } else if action == .askEachTime || kind == .psi {
            #expect(decision == .needsConsent(disclosure))
        } else {
            #expect(decision == .allow)
        }
    }

    @Test(arguments: MessageBody.Kind.allCases)
    func everyBodyDisclosure(kind: MessageBody.Kind) async throws {
        let engine = Fixtures.engine()
        let disclosure = try engine.disclosure(for: Fixtures.outbound(Fixtures.body(kind), context: kind == .psi ? Fixtures.psiContext() : .empty))
        let expected: [DisclosedItem]
        switch kind {
        case .hello: expected = [DisclosedItem(category: .agentCard, issue: nil, value: nil)]
        case .reject: expected = []
        case .psi: expected = [DisclosedItem(category: .psi, issue: .activity, value: Fixtures.value)]
        case .propose, .counter, .accept, .query, .answer:
            expected = [DisclosedItem(category: .interest, issue: .activity, value: Fixtures.value)]
        }
        #expect(disclosure == Disclosure(recipient: Fixtures.bob.id, recipientModel: .onDevice, items: expected))
    }

    @Test(arguments: [ModelLocality.onDevice, .none, .privateCloudCompute, .thirdPartyCloud(provider: "example")],
          MessageBody.Kind.allCases)
    func strictLocality(locality: ModelLocality, kind: MessageBody.Kind) async throws {
        let engine = Fixtures.engine(action: .allowOnDevicePeers, onlyOnDevice: true)
        let card = try AgentCard(model: locality, capabilities: [])
        let message = try Fixtures.outbound(Fixtures.body(kind), card: card, context: kind == .psi ? Fixtures.psiContext() : .empty)
        let decision = await engine.evaluate(message)
        if kind != .hello && locality != .onDevice && locality != .none {
            #expect(decision == .deny(PolicyViolation(rule: PolicyRuleID.onDeviceOnly)))
        } else if kind == .psi {
            #expect(decision == .needsConsent(try engine.disclosure(for: message)))
        } else {
            #expect(decision == .allow)
        }
    }

    @Test(arguments: MessageBody.Kind.allCases, [false, true])
    func missingCard(kind: MessageBody.Kind, strict: Bool) async throws {
        let engine = Fixtures.engine(action: .allowOnDevicePeers, onlyOnDevice: strict)
        let message = try Fixtures.outbound(Fixtures.body(kind), card: nil, context: kind == .psi ? Fixtures.psiContext() : .empty)
        let decision = await engine.evaluate(message)
        if kind == .hello {
            #expect(decision == .allow)
        } else if strict {
            #expect(decision == .deny(PolicyViolation(rule: PolicyRuleID.onDeviceOnly)))
        } else {
            #expect(decision == .needsConsent(try engine.disclosure(for: message)))
        }
    }

    @Test(arguments: [ModelLocality.privateCloudCompute, .thirdPartyCloud(provider: "example")])
    func cloudRequiresConsentWithoutStrictSetting(locality: ModelLocality) async throws {
        let engine = Fixtures.engine(action: .allowOnDevicePeers)
        let message = try Fixtures.outbound(Fixtures.body(.query), card: AgentCard(model: locality, capabilities: []))
        #expect(await engine.evaluate(message) == .needsConsent(try engine.disclosure(for: message)))
    }

    @Test func unspecifiedRuleAndUnpairedPeerRequireConsent() async throws {
        for engine in [Fixtures.engine(), Fixtures.engine(action: .allowOnDevicePeers, paired: false)] {
            let message = try Fixtures.outbound(Fixtures.body(.query))
            #expect(await engine.evaluate(message) == .needsConsent(try engine.disclosure(for: message)))
        }
    }

    @Test func duplicateRulesUseMostRestrictiveRegardlessOfOrder() async throws {
        let actions: [DisclosureRule.Action] = [.never, .askEachTime, .allowOnDevicePeers]
        for ordered in [actions, actions.reversed()] {
            let engine = DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty, disclosure:
                ordered.map { DisclosureRule(issue: .activity, action: $0) }))
            #expect(await engine.evaluate(try Fixtures.outbound(Fixtures.body(.query))) ==
                    .deny(PolicyViolation(rule: PolicyRuleID.never, issue: .activity)))
        }
        let engine = DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty, disclosure: [
            DisclosureRule(issue: .activity, action: .allowOnDevicePeers),
            DisclosureRule(issue: .activity, action: .askEachTime),
        ]), pairedPeers: InMemoryPairedPeerStore([Fixtures.bob]))
        let message = try Fixtures.outbound(Fixtures.body(.query))
        #expect(await engine.evaluate(message) == .needsConsent(try engine.disclosure(for: message)))
    }

    @Test func allValuesArePreservedAndIssuesSorted() async throws {
        let custom = try IssueKey("custom_flag")
        let values: [IssueKey: IssueValue] = [
            .time: .slots([try TimeSlot(startMinute: 100, endMinute: 200)]),
            .activity: Fixtures.value, .budget: .amount(try MoneyAmount(minorUnits: 1575)),
            .partySize: .count(3), custom: .flag(false), .place: .keywords([]),
        ]
        let body = MessageBody.propose(try Proposal(round: 0, terms: Terms(values)))
        let disclosure = try Fixtures.engine().disclosure(for: Fixtures.outbound(body))
        #expect(disclosure.items.compactMap(\.issue) == values.keys.sorted())
        #expect(Dictionary(uniqueKeysWithValues: disclosure.items.map { ($0.issue!, $0.value!) }) == values)
        #expect(disclosure.items.first(where: { $0.issue == .time })?.category == .availability)
        #expect(disclosure.items.first(where: { $0.issue == custom })?.category == .terms)
    }

    @Test func valueFreeAnswersAndEmptyTermsDiscloseNoOwnerValues() async throws {
        let engine = Fixtures.engine(action: .never)
        for status in [Answer.Status.declined, .pendingOwner] {
            let body = MessageBody.answer(try Answer(query: MessageID(), issue: .activity, status: status))
            #expect(try engine.disclosure(for: Fixtures.outbound(body)).items.isEmpty)
            #expect(await engine.evaluate(try Fixtures.outbound(body)) == .allow)
        }
        #expect(try engine.disclosure(for: Fixtures.outbound(.propose(Proposal(round: 0, terms: .empty)))).items.isEmpty)
    }

    @Test func neverWinsOverConsentForOtherIssues() async throws {
        let engine = Fixtures.engine(action: .never)
        let body = MessageBody.propose(try Proposal(round: 0, terms: Terms([
            .activity: Fixtures.value, .budget: .amount(MoneyAmount(minorUnits: 100)),
        ])))
        #expect(await engine.evaluate(try Fixtures.outbound(body)) ==
                .deny(PolicyViolation(rule: PolicyRuleID.never, issue: .activity)))
    }

    @Test(arguments: ["down", "maybe"], [DisclosureRule.Action.never, .askEachTime, .allowOnDevicePeers])
    func acceptedDownLevelUsesOwnerRuleAndClearConsent(level: String, action: DisclosureRule.Action) async throws {
        let value = IssueValue.keywords([try Keyword(level)])
        let engine = DeterministicPolicyEngine(ownerRules: OwnerRules(constraints: .empty, disclosure: [
            DisclosureRule(issue: .downLevel, action: action),
        ]), pairedPeers: InMemoryPairedPeerStore([Fixtures.bob]))
        let message = try Fixtures.outbound(.accept(Acceptance(proposal: MessageID(), terms: Terms([.downLevel: value]))))
        let disclosure = try engine.disclosure(for: message)
        #expect(disclosure.items == [DisclosedItem(category: .interest, issue: .downLevel, value: value)])
        let row = try #require(ConsentSheetModel(disclosure: disclosure).rows.first)
        #expect(row.title == "Your interest")
        #expect(row.detail == "You said \"\(level)\".")
        let expected: PolicyDecision = switch action {
        case .never: .deny(PolicyViolation(rule: PolicyRuleID.never, issue: .downLevel))
        case .askEachTime: .needsConsent(disclosure)
        case .allowOnDevicePeers: .allow
        }
        #expect(await engine.evaluate(message) == expected)
        #expect(await Fixtures.engine().evaluate(message) == .needsConsent(disclosure))
    }
}
