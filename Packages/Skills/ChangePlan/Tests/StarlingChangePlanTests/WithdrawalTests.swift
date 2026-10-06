import Foundation
import StarlingChaining
import StarlingChangePlan
import StarlingCore
import StarlingFakes
import Testing

/// Stops the offer to one person before it leaves, as a send that fails
/// partway through a suggestion's offers.
actor FailingObserver: OutboxObserver {
    struct Refused: Error {}
    let recipient: PeerID
    init(recipient: PeerID) { self.recipient = recipient }
    func outbox(willSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async throws {
        if envelope.recipient == recipient, case .propose = envelope.body { throw Refused() }
    }
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {}
}

/// Holds the first offer to one person once it has left, before Outbox
/// returns it: an offer still sending while the others have returned.
actor OfferGate: OutboxObserver {
    let gate = Gate()
    let recipient: PeerID
    private var done = false
    init(recipient: PeerID) { self.recipient = recipient }
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision) async {}
    func outbox(didSend envelope: Envelope, context: OutboundContext, decision: PolicyDecision, disclosed: [DisclosedItem]?) async {
        guard !done, envelope.recipient == recipient, case .propose = envelope.body else { return }
        done = true
        await gate.pass()
    }
}

/// Final review of PR #111, finding 3: a yes holds the plan no longer than
/// the window and a grace, and a suggestion that ends without a change is
/// withdrawn from everyone it reached, resent until acknowledged.
@Suite struct WithdrawalTests {
    let alex = Fixtures.alex, maya = Fixtures.maya, jake = Fixtures.jake

    /// Alex suggests the later time (window to minute 40); Maya says yes.
    @discardableResult
    func mayaSaidYes(_ group: Group) async throws -> Interaction {
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await group.network.deliver()
        try await group.network.until("cards up") { await ReliabilityTests.cardsUp(group) }
        try await group.phone(maya).service.answer(try await group.card(of: maya).id, with: .accept(proposal: 1))
        await group.network.deliver()
        return link
    }

    func released(_ group: Group, _ person: PeerID) async -> Bool {
        await group.phone(person).holds.holder(of: group.origin) == nil
    }

    @Test func aYesHoldsThePlanOnlyUntilAGraceAfterTheWindow() async throws {
        let group = Group()
        let network = group.network
        try await mayaSaidYes(group)
        // Alex's phone goes dark: no confirmation and no withdrawal come.
        await group.phone(alex).service.shutdown()
        group.clock.advance(to: Fixtures.date(minutes: 41))
        await network.settle()
        #expect(!(await released(group, maya)))
        // A grace (15 minutes) after the window, the card ends and the plan
        // is free again: Maya can suggest a change of her own.
        group.clock.advance(to: Fixtures.date(minutes: 56))
        try await network.until("Maya's hold ended") { await released(group, maya) }
        try await network.until("Maya's card ended") { await group.phone(maya).changes().first?.state == .ended(.expired) }
        let link = try await group.suggest(.change(time: nil, activity: Fixtures.dinner, adding: nil), by: maya)
        #expect(await group.phone(maya).holds.holder(of: group.origin) == link.conversation)
        await network.shutdown()
    }

    @Test func aConfirmationThatComesAfterTheGraceStillApplies() async throws {
        let group = Group()
        let network = group.network
        // Maya and Jake say yes; Alex commits, but every confirmation to
        // Maya is lost until well after the window and its grace.
        try await ReliabilityTests.agreed(group, losing: (0..<8).map { _ in ("Alex > Maya: accept", skipping: 0) })
        try await network.until("Jake applied") { await group.phone(jake).plan(group.origin)?.revision == 1 }
        group.clock.advance(to: Fixtures.date(minutes: 56))
        try await network.until("Maya's card ended") { await group.phone(maya).changes().first?.state == .ended(.expired) }
        #expect(await released(group, maya))
        #expect(await group.phone(maya).plan(group.origin)?.revision == 0)
        // The next resends get through: Maya applies and acknowledges.
        for _ in 0..<12 where await group.phone(maya).plan(group.origin)?.revision != 1 {
            group.clock.advance(to: group.clock.now.addingTimeInterval(300))
            await network.settle()
            await network.deliver()
            await network.settle()
        }
        #expect(await group.phone(maya).plan(group.origin)?.revision == 1)
        #expect(await group.phone(maya).plan(group.origin)?.time == Fixtures.later)
        try await network.until("Alex's delivery done") { (try? await group.phone(alex).journal.records().isEmpty) == true }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aSendThatFailsPartwayStillWithdrawsTheOffersThatWentOut() async throws {
        let observer = FailingObserver(recipient: Fixtures.jake)
        let group = Group(observer: { person, _ in person == Fixtures.alex ? observer : nil })
        let network = group.network
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        #expect(await group.phone(alex).interaction(link.id)?.state == .ended(.failed))
        // Maya's offer went out before Jake's failed: it is withdrawn.
        try await network.until("Maya's card closed") {
            await network.deliver()
            return await group.phone(maya).changes().first?.state.isFinal == true
        }
        #expect(network.transcript.contains("Alex > Maya: reject"))
        #expect(await released(group, maya))
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aSuggestersRestartWhileAskingWithdrawsItsOffers() async throws {
        let group = Group()
        let network = group.network
        let link = try await mayaSaidYes(group)
        #expect(!(await released(group, maya)))
        await group.phone(alex).restart()
        try await network.until("Alex's failed") { await group.phone(alex).interaction(link.id)?.state == .ended(.failed) }
        await network.deliver()
        try await network.until("Maya's card closed") { await group.phone(maya).changes().first?.state.isFinal == true }
        #expect(await released(group, maya))
        try await network.until("acknowledged") { (try? await group.phone(alex).journal.records().isEmpty) == true }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aLostWithdrawalIsResentUntilAcknowledged() async throws {
        let group = Group()
        let network = group.network
        let link = try await mayaSaidYes(group)
        network.drop("Alex > Maya: reject")
        await group.phone(alex).service.withdraw(link.id)
        await network.deliver()
        #expect(!(await released(group, maya)))
        try await ReliabilityTests.resend(group, after: 5, from: group.phone(alex))
        try await network.until("Maya's card closed") { await group.phone(maya).changes().first?.state.isFinal == true }
        #expect(await released(group, maya))
        try await network.until("acknowledged") { (try? await group.phone(alex).journal.records().isEmpty) == true }
        await network.shutdown()
    }

    @Test func anOfferStillInFlightWhenWithdrawnIsWithdrawnToo() async throws {
        let observer = ArmedObserver()
        await observer.arm()
        let group = Group(observer: { person, _ in person == Fixtures.alex ? observer : nil })
        let network = group.network
        // Alex's offer to Maya has left, but Outbox has not returned it yet.
        let suggesting = Task { try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex) }
        await observer.gate.arrived()
        let link = try #require(await group.phone(alex).changes().first)
        await group.phone(alex).service.withdraw(link.id)
        await observer.gate.open()
        _ = try? await suggesting.value
        await network.deliver()
        try await network.until("withdrawn") { network.transcript.contains("Alex > Maya: reject") }
        await network.deliver()
        try await network.until("Maya's card closed") {
            await network.deliver()
            return await group.phone(maya).changes().allSatisfy(\.state.isFinal)
        }
        #expect(await released(group, maya))
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    /// Re-review of PR #111, item 2: Maya acknowledges the withdrawal of
    /// her offer while Alex's offer to Jake is still sending. The delivery
    /// stays open until that send returns, and Jake's offer is withdrawn too.
    @Test func aWithdrawalAcknowledgedWhileAnotherOfferSendsStillWithdrawsThatOne() async throws {
        let observer = OfferGate(recipient: Fixtures.jake)
        let group = Group(observer: { person, _ in person == Fixtures.alex ? observer : nil })
        let network = group.network
        let suggesting = Task { try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex) }
        await observer.gate.arrived()
        let link = try #require(await group.phone(alex).changes().first)
        await group.phone(alex).service.withdraw(link.id)
        // Maya gets her offer and its withdrawal, and acknowledges it.
        await network.deliver()
        try await network.until("Maya acknowledged") { network.transcript.contains("Maya > Alex: accept") }
        await network.settle()
        await observer.gate.open()
        _ = try? await suggesting.value
        try await network.until("Jake's card closed") {
            await network.deliver()
            return await group.phone(jake).changes().allSatisfy(\.state.isFinal)
        }
        #expect(network.transcript.contains("Alex > Jake: reject"))
        #expect(await released(group, jake))
        try await network.until("acknowledged") { (try? await group.phone(alex).journal.records().isEmpty) == true }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }
}
