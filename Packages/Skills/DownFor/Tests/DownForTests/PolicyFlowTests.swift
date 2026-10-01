import Foundation
@testable import DownFor
import StarlingCore
import StarlingFakes
import StarlingPolicy
import Testing

/// Down for... through lane G's real policy engine with the default privacy
/// topics (ADR 0014): time and activity Share, everything else Ask me.
@Suite(.timeLimit(.minutes(1))) struct PolicyFlowTests {
    static func world(_ count: Int, consent: ScriptedConsentProvider) -> World {
        let rules = OwnerRules(constraints: .empty, disclosure: PrivacySettings.defaults.disclosureRules)
        return World(count, policy: DeterministicPolicyEngine(ownerRules: rules), consent: consent)
    }

    /// Every phone has every other phone's card: on-device, with the skill.
    static func exchangeCards(_ world: World) async throws {
        let card = try AgentCard(model: .onDevice, capabilities: [.psi], skills: [DownFor.ref])
        for phone in world.phones {
            for other in world.phones where other !== phone {
                let hello = try Envelope(conversation: ConversationID(), sender: other.id, recipient: phone.id, sequence: 0, sentAt: Timestamp(T.now), body: .hello(card))
                await phone.service.handle(.message(hello))
            }
        }
    }

    @Test func aPairPlanNeverAsksAboutPeople() async throws {
        let consent = ScriptedConsentProvider(.approved)
        let world = Self.world(2, consent: consent)
        try await world.start()
        defer { Task { await world.stop() } }
        try await Self.exchangeCards(world)
        let (a, b) = (world["A"], world["B"])

        let mine = try await a.down(for: ["boba"], with: [b])
        let theirs = try await b.down(for: ["boba"], with: [a])
        try await a.waitForProposal(mine)
        try await b.waitForProposal(theirs)
        try await a.imIn(mine)
        try await b.imIn(theirs)
        try await a.waitFor(.planned, mine)
        try await b.waitFor(.planned, theirs)

        let sheets = await consent.requests
        // The stub PSI is not private, so finding time asks; the roster of
        // two is never sent, so nothing asks about people.
        #expect(sheets.contains { $0.items.contains { $0.category == .psi && $0.issue == .time } })
        #expect(!sheets.contains { $0.items.contains { $0.issue == .people } })
        #expect(sheets.allSatisfy { $0.skill == DownFor.ref && $0.conversation != nil })
        await world.expectCleanLifecycles()
    }

    @Test func aGroupPlanShowsTheRosterOnTheSheet() async throws {
        let consent = ScriptedConsentProvider(.approved)
        let world = Self.world(3, consent: consent)
        try await world.start()
        defer { Task { await world.stop() } }
        try await Self.exchangeCards(world)
        let (a, b, c) = (world["A"], world["B"], world["C"])

        let ids = [
            try await a.down(for: ["boba"], with: [b, c]),
            try await b.down(for: ["boba"], with: [a, c]),
            try await c.down(for: ["boba"], with: [a, b]),
        ]
        for (phone, id) in zip([a, b, c], ids) {
            try await eventually("\(phone.name) sees all three") { await phone.lifecycle.interaction(id)?.proposal?.participants.count == 3 }
            try await phone.imIn(id)
        }
        for (phone, id) in zip([a, b, c], ids) { try await phone.waitFor(.planned, id) }

        // "Who else is in this" is on the sheet, as the people topic asks.
        let roster = IssueValue.peers([a.id, b.id, c.id])
        #expect(await consent.requests.contains { $0.items.contains { $0.issue == .people && $0.value == roster } })
        await world.expectCleanLifecycles()
    }
}
