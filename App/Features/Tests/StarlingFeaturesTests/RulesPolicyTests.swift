import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

/// Records the rules each engine was built with and answers per rule set.
final class EngineFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var built: [OwnerRules] = []
    var snapshots: [OwnerRules] { lock.withLock { built } }

    /// Denies anything whose rules say "never" for place; asks otherwise.
    func make(_ rules: OwnerRules) -> any PolicyEngine {
        lock.withLock { built.append(rules) }
        let neverPlace = rules.disclosure.contains(DisclosureRule(issue: .place, action: .never))
        return FixedPolicyEngine(decide: { message in
            neverPlace
                ? .deny(PolicyViolation(rule: "never", issue: .place))
                : .needsConsent(Disclosure(recipient: message.envelope.recipient, recipientModel: nil, items: [], conversation: message.envelope.conversation, skill: message.envelope.skill))
        })
    }
}

@Suite struct RulesPolicyTests {
    static func message() throws -> OutboundMessage {
        let envelope = try Envelope(conversation: ConversationID(), sender: .random(), recipient: .random(), sequence: 0,
                                    sentAt: Timestamp(Fixtures.noon), body: .propose(try Proposal(round: 0, terms: .empty)))
        return OutboundMessage(envelope: envelope, recipientCard: nil, transport: .loopback)
    }

    @Test func deniesEverythingUntilRulesAreLoaded() async throws {
        let policy = RulesPolicy(make: EngineFactory().make)
        #expect(await policy.evaluate(try Self.message()) == .deny(PolicyViolation(rule: RulesPolicy.notLoadedRule)))
    }

    @Test func judgesWithTheLatestRules() async throws {
        let factory = EngineFactory()
        let policy = RulesPolicy(make: factory.make)
        await policy.update(.empty)
        guard case .needsConsent = await policy.evaluate(try Self.message()) else { Issue.record("expected consent"); return }

        await policy.update(OwnerRules(constraints: .empty, disclosure: [DisclosureRule(issue: .place, action: .never)]))
        #expect(await policy.evaluate(try Self.message()) == .deny(PolicyViolation(rule: "never", issue: .place)))

        await policy.update(OwnerRules(constraints: .empty, disclosure: [DisclosureRule(issue: .place, action: .never)]))
        #expect(factory.snapshots.count == 2, "unchanged rules do not rebuild the engine")
    }
}
