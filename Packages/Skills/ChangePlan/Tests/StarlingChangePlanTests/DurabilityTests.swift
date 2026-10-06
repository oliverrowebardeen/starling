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
        #expect(network.transcript.suffix(4) == ["Alex > Maya: reject", "Alex > Jake: reject", "Maya > Alex: accept", "Jake > Alex: accept"])
        #expect(try await group.phone(alex).journal.records().isEmpty)
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    /// The commit's record lands after the withdrawal's and replaces it (one
    /// key per suggestion). The withdrawal must still be on record, so a
    /// restart resends the ones Maya and Jake lost.
    @Test func aWithdrawalDuringTheCommitIsStillResentAfterARestart() async throws {
        let group = Group()
        let network = group.network
        let phone = group.phone(alex)
        await phone.journal.hold { $0.isConfirming }
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("cards up") { await ReliabilityTests.cardsUp(group) }
        for person in [maya, jake] {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        network.drop("Alex > Maya: reject")
        network.drop("Alex > Jake: reject")
        let delivering = Task { await network.deliver() }
        try await network.until("commit held") { await phone.journal.held == 1 }
        await phone.service.withdraw(link.id)
        await phone.journal.release()
        await delivering.value
        await network.deliver()
        await network.settle()
        for person in [maya, jake] { #expect(await group.phone(person).changes().first?.state.isFinal == false) }
        await phone.restart()
        await network.deliver()
        try await network.until("cards closed") {
            for person in [maya, jake] where await group.phone(person).changes().first?.state.isFinal != true { return false }
            return true
        }
        try await network.until("Alex's withdrawal done") { (try? await phone.journal.records().isEmpty) == true }
        #expect(await ReliabilityTests.revisions(group, [alex, maya, jake]) == [0, 0, 0])
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    /// A journal restored with someone listed twice in a suggestion's asked
    /// roster (a corrupted file, or one an older build wrote) must not trap
    /// the app on launch. Everyone is still told once that it is withdrawn.
    @Test func aRestoredSuggestionThatNamesSomeoneTwiceIsStillWithdrawn() async throws {
        let group = Group()
        let network = group.network
        let phone = group.phone(alex)
        _ = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("cards up") { await ReliabilityTests.cardsUp(group) }
        let open = try #require(try await phone.journal.records().lazy.compactMap { record -> OpenSuggestion? in
            if case .asking(let open) = record { open } else { nil }
        }.first)
        #expect(Set(open.offers.keys) == [maya, jake])
        // Everyone asked is listed twice, as a damaged journal read back
        // from disk could have them.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(open)) as? [String: Any])
        let asked = try #require(object["asked"] as? [Any])
        object["asked"] = asked + asked
        let doubled = try JSONDecoder().decode(OpenSuggestion.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(doubled.asked == open.asked + open.asked)
        try await phone.journal.saveNow(.asking(doubled))
        await phone.restart()
        await network.deliver()
        try await network.until("cards closed") {
            for person in [maya, jake] where await group.phone(person).changes().first?.state.isFinal != true { return false }
            return true
        }
        try await network.until("Alex's withdrawal done") { (try? await phone.journal.records().isEmpty) == true }
        #expect(await ReliabilityTests.revisions(group, [alex, maya, jake]) == [0, 0, 0])
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

    /// Final review of PR #111, finding 2: Jake's app is killed after his
    /// notices go out but before his plan's withdrawal is saved. On relaunch
    /// his plan ends, and the notice Maya missed goes out again.
    @Test func aLeaveTheCrashInterruptedEndsTheLeaversPlanOnRestart() async throws {
        let group = Group()
        let network = group.network
        let phone = group.phone(jake)
        phone.losingEverything.set(true)
        network.drop("Jake > Maya: propose")
        let leave = try await group.suggest(.leave, by: jake)
        await network.deliver()
        try await network.until("Alex's plan shrank") { await group.phone(alex).plan(group.origin)?.attendees.peers == [alex, maya] }
        // Nothing reached Jake's store: his plan still stands.
        #expect(await phone.plan(group.origin) != nil)
        #expect(await phone.interaction(leave.id)?.state.isFinal == false)
        await phone.restart()
        try await network.until("Jake's plan ended") { await phone.plan(group.origin) == nil }
        #expect(await phone.interaction(group.roots[jake]!.id)?.state == .ended(.withdrawn))
        #expect(await phone.interaction(leave.id)?.state == .ended(.withdrawn))
        #expect(try await phone.ledger.isRetired(group.origin))
        // The notice Maya missed went out again at once.
        await network.deliver()
        try await network.until("Maya's plan shrank") { await group.phone(maya).plan(group.origin)?.attendees.peers == [alex, maya] }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    /// Final review of PR #111, finding 5: Alex's commit was journaled but
    /// the app died before it applied, and by the relaunch another change
    /// had moved Alex's plan. The commit is not resent: Maya and Jake are
    /// told it is withdrawn, and no phone applies it.
    @Test func aCommitThatWasNeverAppliedIsAbandonedOnRestart() async throws {
        let group = Group()
        let network = group.network
        let phone = group.phone(alex)
        await phone.journal.hold { $0.isConfirming }
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("cards up") { await ReliabilityTests.cardsUp(group) }
        for person in [maya, jake] {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        let delivering = Task { await network.deliver() }
        try await network.until("commit being written") { await phone.journal.held == 1 }
        // The write lands, and the app dies before anything else happens.
        let record = try #require(await phone.journal.heldRecords.first)
        try await phone.journal.saveNow(record)
        await phone.journal.stopHolding()
        // Another change moved Alex's plan meanwhile.
        var root = try #require(await phone.interaction(group.roots[alex]!.id))
        root.record(.plan(try #require(root.plan).updating(activity: .some(Fixtures.dinner))))
        try await phone.store.save(root)
        await phone.restart()
        await network.deliver()
        try await network.until("cards closed") {
            for person in [maya, jake] where await group.phone(person).changes().first?.state.isFinal != true { return false }
            return true
        }
        #expect(Self.sent(network, "Alex > Maya: accept") == 0 && Self.sent(network, "Alex > Jake: accept") == 0)
        #expect(await ReliabilityTests.revisions(group, [maya, jake]) == [0, 0])
        #expect(await phone.plan(group.origin)?.activity == Fixtures.dinner)
        #expect(await phone.interaction(link.id)?.state == .ended(.nobodyUp))
        // Let the first launch's write finish, after the checks.
        await phone.journal.release()
        _ = await delivering.value
        await network.shutdown()
    }

    /// The other side of finding 5: Alex's commit applied and its
    /// confirmations went out, but the app died before it saved anything
    /// the service told it. The plan still stands at the basis, so the
    /// commit is finished on relaunch, not withdrawn.
    @Test func aCommitWhoseEventsWereAllLostIsFinishedOnRestart() async throws {
        let group = Group()
        let network = group.network
        let phone = group.phone(alex)
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: alex)
        await network.deliver()
        try await network.until("cards up") { await ReliabilityTests.cardsUp(group) }
        phone.losingEverything.set(true)
        for person in [maya, jake] {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        // The yeses go through; the acknowledgments are lost.
        network.drop("Maya > Alex: accept", skipping: 1)
        network.drop("Jake > Alex: accept", skipping: 1)
        await network.deliver()
        try await network.until("Maya and Jake applied") { await ReliabilityTests.revisions(group, [maya, jake]) == [1, 1] }
        #expect(await phone.plan(group.origin)?.revision == 0)
        #expect(await phone.interaction(link.id)?.state != .planned)
        await phone.restart()
        try await network.until("Alex's commit finished") { await phone.interaction(link.id)?.state == .planned }
        #expect(await phone.plan(group.origin)?.time == Fixtures.later)
        #expect(await phone.plan(group.origin)?.revision == 1)
        await network.deliver()
        try await network.until("Alex's delivery done") { (try? await phone.journal.records().isEmpty) == true }
        #expect(Self.sent(network, "Alex > Maya: reject") == 0 && Self.sent(network, "Alex > Jake: reject") == 0)
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
