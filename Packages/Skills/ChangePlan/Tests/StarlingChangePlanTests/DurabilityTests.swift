import Foundation
import StarlingChaining
import StarlingChangePlan
import StarlingCore
import StarlingFakes
import Testing

/// A change survives late confirmations, restarts, and a journal that cannot
/// write (Codex re-review of PR #111, findings 1 to 3; issues #116, #117).
@Suite struct DurabilityTests {
    let alex = Fixtures.alex, maya = Fixtures.maya, jake = Fixtures.jake

    static func sent(_ network: Network, _ line: String) -> Int { network.transcript.filter { $0 == line }.count }

    // MARK: Finding 1, issue #116: a yes holds until its confirmation can no longer come

    @Test func aConfirmationResentAfterTheVotersWindowStillApplies() async throws {
        let group = Group()
        let network = group.network
        // The first two confirmations to Jake are lost.
        try await ReliabilityTests.agreed(group, losing: [("Alex > Jake: accept", skipping: 0), ("Alex > Jake: accept", skipping: 0)])
        try await network.until("Maya applied") { await group.phone(maya).plan(group.origin)?.revision == 1 }
        // Jake's decision window closes (minute 40) before the resend gets through.
        try await ReliabilityTests.resend(group, after: 31 * 60, from: group.phone(alex))
        await network.settle()
        let card = try #require(await group.phone(jake).changes().first)
        #expect(!card.state.isFinal)
        // The next resend applies, and Jake acknowledges it.
        try await ReliabilityTests.resend(group, after: 600, from: group.phone(alex))
        try await network.until("Jake applied") { await group.phone(jake).plan(group.origin)?.revision == 1 }
        try await network.until("Alex's delivery done") {
            (try? await group.phone(alex).journal.records().contains(where: \.isConfirming)) == false
        }
        #expect(await group.phone(jake).interaction(card.id)?.state == .planned)
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aYesSurvivesARestartBeforeItsConfirmationArrives() async throws {
        let group = Group()
        let network = group.network
        try await ReliabilityTests.agreed(group, losing: [("Alex > Jake: accept", skipping: 0)])
        try await network.until("Maya applied") { await group.phone(maya).plan(group.origin)?.revision == 1 }
        // Jake's app relaunches between his yes and the confirmation.
        await group.phone(jake).restart()
        try await ReliabilityTests.resend(group, after: 5, from: group.phone(alex))
        try await network.until("Jake applied") { await group.phone(jake).plan(group.origin)?.revision == 1 }
        #expect(await group.phone(jake).changes().first?.state == .planned)
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    /// Lane F's PC06: once the plan has moved past the card's basis, its
    /// confirmation can never apply, so the card closes with its window.
    @Test func aYesWhosePlanMovedOnClosesWithItsWindow() async throws {
        let group = Group()
        let network = group.network
        try await ReliabilityTests.agreed(group, losing: [("Alex > Jake: accept", skipping: 0), ("Alex > Jake: accept", skipping: 0)])
        try await network.until("Maya applied") { await group.phone(maya).plan(group.origin)?.revision == 1 }
        // Another change moves Jake's plan on before the confirmation arrives.
        let jake = group.phone(self.jake)
        var root = try #require(await jake.interaction(group.roots[self.jake]!.id))
        root.record(.plan(try #require(root.plan).updating(activity: .some(Fixtures.dinner))))
        try await jake.store.save(root)
        group.clock.advance(to: Fixtures.date(minutes: 41))
        try await network.until("Jake's card closed") { await jake.changes().first?.state.isFinal == true }
        #expect(await jake.changes().first?.state == .ended(.expired))
        #expect(await jake.plan(group.origin)?.activity == Fixtures.dinner)
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func theSuggesterTellsEveryoneWhenTheWindowClosesSoTheirCardsClose() async throws {
        let group = Group()
        let network = group.network
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex, expiresIn: 30)
        await network.deliver()
        try await network.until("cards up") { await ReliabilityTests.cardsUp(group) }
        try await group.phone(maya).service.answer(try await group.card(of: maya).id, with: .accept(proposal: 1))
        await network.deliver()
        // Jake never answers; the window closes.
        group.clock.advance(to: Fixtures.date(minutes: 41))
        try await network.until("Alex's ended") { await group.phone(alex).interaction(link.id)?.state.isFinal == true }
        await network.deliver()
        try await network.until("Maya's card closed") { await group.phone(maya).changes().first?.state.isFinal == true }
        #expect(await group.phone(maya).changes().first?.state == .ended(.expired))
        // Her yes is no longer kept.
        #expect(try await group.phone(maya).journal.records().isEmpty)
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    // MARK: Finding 2: a withdrawal while the commit is recorded commits nothing

    @Test func withdrawingWhileTheCommitIsBeingRecordedCommitsNothing() async throws {
        let group = Group()
        let network = group.network
        await group.phone(alex).journal.hold { $0.isConfirming }
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("cards up") { await ReliabilityTests.cardsUp(group) }
        for person in [maya, jake] {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        // Everyone said yes; the commit waits on the journal (delivery waits
        // with it). Alex withdraws.
        let delivering = Task { await network.deliver() }
        try await network.until("commit held") { await group.phone(alex).journal.held == 1 }
        await group.phone(alex).service.withdraw(link.id)
        await group.phone(alex).journal.release()
        await delivering.value
        await network.deliver()
        await network.settle()
        #expect(await ReliabilityTests.revisions(group, [alex, maya, jake]) == [0, 0, 0])
        #expect(Self.sent(network, "Alex > Maya: accept") == 0 && Self.sent(network, "Alex > Jake: accept") == 0)
        #expect(network.transcript.suffix(2) == ["Alex > Maya: reject", "Alex > Jake: reject"])
        #expect(try await group.phone(alex).journal.records().isEmpty)
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    // MARK: Finding 3: a commit or update the crash interrupted is replayed

    @Test func theSuggestersCommitIsReplayedIfItsUpdateWasLost() async throws {
        let group = Group()
        let network = group.network
        // Alex's app quits after publishing the update but before saving it,
        // and before any acknowledgment arrives.
        group.phone(alex).losingUpdates.set(true)
        try await ReliabilityTests.agreed(group, losing: [("Maya > Alex: accept", skipping: 1), ("Jake > Alex: accept", skipping: 1)])
        try await network.until("Maya and Jake applied") { await ReliabilityTests.revisions(group, [maya, jake]) == [1, 1] }
        #expect(await group.phone(alex).plan(group.origin)?.revision == 0)
        await group.phone(alex).restart()
        try await network.until("Alex's plan replayed") { await group.phone(alex).plan(group.origin)?.revision == 1 }
        #expect(await group.phone(alex).plan(group.origin)?.time == Fixtures.later)
        await network.deliver()
        try await network.until("Alex's delivery done") { (try? await group.phone(alex).journal.records().isEmpty) == true }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aFriendsUpdateIsReplayedIfItWasLostBeforeItWasSaved() async throws {
        let group = Group()
        let network = group.network
        group.phone(jake).losingUpdates.set(true)
        try await ReliabilityTests.agreed(group)
        try await network.until("Jake's card planned") { await group.phone(jake).changes().first?.state == .planned }
        #expect(await group.phone(jake).plan(group.origin)?.revision == 0)
        await group.phone(jake).restart()
        try await network.until("Jake's plan replayed") { await group.phone(jake).plan(group.origin)?.revision == 1 }
        #expect(await ReliabilityTests.revisions(group, [alex, maya, jake]) == [1, 1, 1])
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aDepartureIsReplayedIfItsUpdateWasLost() async throws {
        let group = Group()
        let network = group.network
        group.phone(maya).losingUpdates.set(true)
        try await group.suggest(.leave, by: jake)
        await network.deliver()
        try await network.until("Maya acknowledged") { Self.sent(network, "Maya > Jake: accept") == 1 }
        #expect(await group.phone(maya).plan(group.origin)?.attendees.peers == [alex, maya, jake])
        await group.phone(maya).restart()
        try await network.until("Maya's plan shrank") { await group.phone(maya).plan(group.origin)?.attendees.peers == [alex, maya] }
        #expect(await group.phone(maya).plan(group.origin)?.revision == 1)
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    // MARK: Issue #117: what cannot be recorded does not happen

    @Test func aCommitThatCannotBeRecordedChangesNothing() async throws {
        let group = Group()
        let network = group.network
        await group.phone(alex).journal.fail { $0.isConfirming }
        let link = try await ReliabilityTests.agreed(group)
        try await network.until("Alex's ended") { await group.phone(alex).interaction(link.id)?.state.isFinal == true }
        await network.deliver()
        try await network.until("cards closed") {
            for person in [maya, jake] where await group.phone(person).changes().first?.state.isFinal != true { return false }
            return true
        }
        #expect(await ReliabilityTests.revisions(group, [alex, maya, jake]) == [0, 0, 0])
        #expect(await group.phone(alex).interaction(link.id)?.state == .ended(.nobodyUp))
        #expect(Self.sent(network, "Alex > Maya: accept") == 0 && Self.sent(network, "Alex > Jake: accept") == 0)
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aYesThatCannotBeRecordedIsNotSent() async throws {
        let group = Group()
        let network = group.network
        try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("Maya's card") { await group.openCard(of: maya) != nil }
        let card = try await group.card(of: maya)
        await group.phone(maya).journal.fail { $0.isAccepted }
        await #expect(throws: ChangePlanError.journalUnavailable) {
            try await group.phone(maya).service.answer(card.id, with: .accept(proposal: 1))
        }
        await network.deliver()
        #expect(Self.sent(network, "Maya > Alex: accept") == 0)
        // Once the journal works again, Maya can still say yes.
        await group.phone(maya).journal.fail { _ in false }
        try await group.phone(maya).service.answer(card.id, with: .accept(proposal: 1))
        await network.deliver()
        #expect(Self.sent(network, "Maya > Alex: accept") == 1)
        await network.shutdown()
    }

    @Test func aConfirmationThatCannotBeRecordedWaitsForTheResend() async throws {
        let group = Group()
        let network = group.network
        await group.phone(jake).journal.fail { $0.isApplied }
        try await ReliabilityTests.agreed(group)
        try await network.until("Maya applied") { await group.phone(maya).plan(group.origin)?.revision == 1 }
        await network.settle()
        // Jake neither applies nor acknowledges.
        #expect(await group.phone(jake).plan(group.origin)?.revision == 0)
        #expect(Self.sent(network, "Jake > Alex: accept") == 1)
        await group.phone(jake).journal.fail { _ in false }
        try await ReliabilityTests.resend(group, after: 5, from: group.phone(alex))
        try await network.until("Jake applied") { await group.phone(jake).plan(group.origin)?.revision == 1 }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aLeaveThatCannotBeRecordedIsNotSent() async throws {
        let group = Group()
        let network = group.network
        await group.phone(jake).journal.fail { $0.isLeaving }
        await #expect(throws: ChangePlanError.journalUnavailable) { try await group.suggest(.leave, by: jake) }
        await network.deliver()
        #expect(network.transcript.isEmpty)
        #expect(await group.phone(alex).plan(group.origin)?.attendees.peers == [alex, maya, jake])
        await network.shutdown()
    }

    @Test func aDepartureThatCannotBeRecordedWaitsForTheResend() async throws {
        let group = Group()
        let network = group.network
        await group.phone(maya).journal.fail { $0.isDeparted }
        try await group.suggest(.leave, by: jake)
        await network.deliver()
        try await network.until("Alex's plan shrank") { await group.phone(alex).plan(group.origin)?.attendees.peers == [alex, maya] }
        await network.settle()
        #expect(await group.phone(maya).plan(group.origin)?.attendees.peers == [alex, maya, jake])
        #expect(Self.sent(network, "Maya > Jake: accept") == 0)
        await group.phone(maya).journal.fail { _ in false }
        try await ReliabilityTests.resend(group, after: 5, from: group.phone(jake))
        try await network.until("Maya's plan shrank") { await group.phone(maya).plan(group.origin)?.attendees.peers == [alex, maya] }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }
}
