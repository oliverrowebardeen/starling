import Foundation
import SimulatorKit
import StarlingCore
import StarlingFakes
import StarlingNegotiation
import StarlingPolicy
import Testing

@Suite(.timeLimit(.minutes(1))) struct DownPolicyFlowTests {
    @Test(arguments: [DownLevel.down, .maybe])
    func mutualMatchUsesRealPolicyConsentAndAudit(level: DownLevel) async throws {
        let rules = try IntegrationFixtures.rules()
        let consent = ScriptedConsentProvider(.approved)
        let config = NodeConfiguration(rules: rules, consent: consent)
        try await withIntegratedWorld([config, config]) { world in
            let a = world.nodes[0], b = world.nodes[1]
            try await a.want(level)
            try await b.want()
            try await Simulation.eventually("both real negotiators match") {
                let aCount = await a.matches.count
                let bCount = await b.matches.count
                return aCount == 1 && bCount == 1
            }
            #expect(await a.matches.first?.terms == b.matches.first?.terms)
            #expect(await a.matches.first?.bothDown == (level == .down))
            #expect(await b.matches.first?.bothDown == (level == .down))
            let requests = await consent.requests
            #expect(!requests.isEmpty)
            let slots = DownTokenSet(constraints: rules.constraints, now: IntegrationFixtures.now,
                                    expiresAt: IntegrationFixtures.expiry, timeZone: IntegrationFixtures.utc).slots
            #expect(requests.allSatisfy { $0.items == [DisclosedItem(category: .psi, issue: .time, value: .slots(slots))] })
            try await world.expectSafeMatches()
            // Exact wire replay must neither repeat a notification nor bypass Inbox.
            let accepts = await world.wire.envelopes.filter { $0.body.kind == .accept }
            for envelope in accepts {
                try await world.hub.inject(Frame(EnvelopeCodec().encode(envelope)), claimedSender: envelope.sender, to: envelope.recipient)
            }
            try await Simulation.eventually("acceptance replays dropped") {
                let aDrops = await a.dropped.count
                let bDrops = await b.dropped.count
                return aDrops + bDrops == accepts.count
            }
            #expect(await a.matches.count == 1)
            #expect(await b.matches.count == 1)
            #expect(await a.dropped.allSatisfy { $0 == .replay })
            #expect(await b.dropped.allSatisfy { $0 == .replay })
        }
    }

    @Test func threePeersNotifyOnlyForMutualOverlap() async throws {
        let overlap = try NodeConfiguration(rules: IntegrationFixtures.rules())
        let disjoint = try NodeConfiguration(rules: IntegrationFixtures.rules(time: IntegrationFixtures.slot(4, 5)))
        try await withIntegratedWorld([overlap, overlap, disjoint]) { world in
            for node in world.nodes { try await node.want(.maybe) }
            try await Simulation.eventually("overlapping peers match") {
                let a = await world.nodes[0].matches.count
                let b = await world.nodes[1].matches.count
                return a == 1 && b == 1
            }
            try await world.waitForTimeouts()
            for (index, node) in world.nodes.enumerated() {
                #expect(await node.matches.count == (index == 2 ? 0 : 1))
                let unrelated = await world.wire.sent(by: node.id).filter { $0.recipient == world.nodes[2].id || index == 2 }
                #expect(unrelated.allSatisfy { $0.body.kind == .psi })
            }
            try await world.expectSafeMatches()
        }
    }

    @Test func oneSidedInterestNeverRaisesConsentOnIdlePeer() async throws {
        let consent = ScriptedConsentProvider(.approved)
        let rules = try IntegrationFixtures.rules()
        try await withIntegratedWorld([NodeConfiguration(rules: rules), NodeConfiguration(rules: rules, consent: consent)]) { world in
            let a = world.nodes[0], b = world.nodes[1]
            try await a.want(.maybe)
            _ = try await b.next(.psi)
            try await world.waitForTimeouts()
            #expect(await b.events.isEmpty)
            #expect(await consent.requests.isEmpty)
            #expect(await world.wire.sent(by: b.id).isEmpty)
            await world.expectSilence(a)
            try await world.expectAudited(b)
        }
    }

    @Test(arguments: [IssueKey.time, .activity, .budget, .downLevel])
    func neverRulesBlockTheRealDownExchange(issue: IssueKey) async throws {
        let protected = try NodeConfiguration(rules: IntegrationFixtures.rules(never: issue))
        let ordinary = try NodeConfiguration(rules: IntegrationFixtures.rules())
        try await withIntegratedWorld([protected, ordinary]) { world in
            let a = world.nodes[0], b = world.nodes[1]
            try await a.want(.maybe)
            try await b.want()
            try await Simulation.eventually("real policy refuses \(issue)") {
                await a.policy.entries.contains { $0.decision == .deny(PolicyViolation(rule: PolicyRuleID.never, issue: issue)) }
            }
            try await world.waitForTimeouts()
            await world.expectSilence(a)
            #expect(await b.matches.isEmpty)
            let denied = await a.policy.entries.filter { if case .deny = $0.decision { true } else { false } }.map(\.message.envelope.id)
            let audited = await a.audit.entries().map(\.message)
            #expect(Set(denied).isDisjoint(with: Set(audited)))
            try await world.expectAudited(a)
            try await world.expectAudited(b)
        }
    }

    @Test func nonPrivatePSIConsentCanStopDownBeforeTheWire() async throws {
        let consent = ScriptedConsentProvider(.declined)
        let rules = try IntegrationFixtures.rules()
        try await withIntegratedWorld([NodeConfiguration(rules: rules, consent: consent), NodeConfiguration(rules: rules)]) { world in
            let a = world.nodes[0], b = world.nodes[1]
            try await a.want(.maybe)
            try await b.want()
            try await Simulation.eventually("PSI disclosure reaches consent") { await !consent.requests.isEmpty }
            try await world.waitForTimeouts()
            #expect(await world.wire.sent(by: a.id).isEmpty)
            #expect(await a.audit.entries().allSatisfy { $0.kind == .hello })
            #expect(await consent.requests.allSatisfy { $0.items.contains { $0.category == .psi && $0.issue == .time && $0.value != nil } })
            await world.expectSilence(a)
            await world.expectSilence(b)
        }
    }

    @Test func cloudCardIsRefusedByOnDeviceOnlyPolicy() async throws {
        let consent = ScriptedConsentProvider(.approved)
        let rules = try IntegrationFixtures.rules()
        let a = NodeConfiguration(rules: rules, consent: consent, onlyOnDevice: true)
        let b = NodeConfiguration(rules: rules, locality: .thirdPartyCloud(provider: "malicious"))
        try await withIntegratedWorld([a, b]) { world in
            for node in world.nodes { try await node.want() }
            try await Simulation.eventually("cloud recipient denied") {
                await world.nodes[0].policy.entries.contains { $0.decision == .deny(PolicyViolation(rule: PolicyRuleID.onDeviceOnly)) }
            }
            try await world.waitForTimeouts()
            #expect(await world.wire.sent(by: world.nodes[0].id).isEmpty)
            #expect(await consent.requests.isEmpty)
            for node in world.nodes { #expect(await node.matches.isEmpty) }
        }
    }

    @Test func withdrawalCancelsARealPSIDisclosurePendingConsent() async throws {
        let consent = ControlledConsent(holding: .time)
        let rules = try IntegrationFixtures.rules()
        try await withIntegratedWorld([NodeConfiguration(rules: rules, consent: consent), NodeConfiguration(rules: rules)]) { world in
            let a = world.nodes[0]
            try await a.want(.maybe)
            try await Simulation.eventually("PSI consent suspended") { await consent.pending == 1 }
            await a.down?.clearIntent()
            await consent.resolve(.approved)
            try await world.waitForTimeouts()
            #expect(await world.wire.sent(by: a.id).isEmpty)
            #expect(await a.audit.entries().allSatisfy { $0.kind == .hello })
            #expect(await a.events.contains(.ended(.withdrawn)))
            await world.expectSilence(a)
        }
    }

    @Test func partitionDoesNotProduceAnAuditReceiptOrMatch() async throws {
        let consent = ControlledConsent(holding: .time)
        let rules = try IntegrationFixtures.rules()
        try await withIntegratedWorld([NodeConfiguration(rules: rules, consent: consent), NodeConfiguration(rules: rules)]) { world in
            let a = world.nodes[0], b = world.nodes[1]
            try await a.want()
            try await Simulation.eventually("first PSI send awaits consent") { await consent.pending == 1 }
            await world.hub.partition(a.id, b.id)
            await consent.resolve(.approved)
            // A second request proves the first approved send failed at the
            // partition and was retried, rather than never being attempted.
            try await Simulation.eventually("lost PSI is retried") { await consent.pending == 1 }
            try await world.waitForTimeouts()
            for node in world.nodes {
                #expect(await node.matches.isEmpty)
                #expect(await world.wire.sent(by: node.id).isEmpty)
                #expect(await node.audit.entries().allSatisfy { $0.kind == .hello })
            }
        }
    }
}
