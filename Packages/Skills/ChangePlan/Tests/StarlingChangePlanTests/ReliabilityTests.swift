import Foundation
import StarlingChaining
import StarlingChangePlan
import StarlingCore
import StarlingFakes
import Testing

/// Confirmations and leave notices reach every phone over a link that loses
/// frames (ADR 0243): resent until acknowledged, acknowledged again when
/// resent, applied once.
@Suite struct ReliabilityTests {
    let alex = Fixtures.alex, maya = Fixtures.maya, jake = Fixtures.jake

    /// Alex's change to the later time, with Maya and Jake both saying yes.
    /// Returns once the yeses are delivered.
    @discardableResult
    static func agreed(_ group: Group, losing frames: [(String, skipping: Int)] = []) async throws -> Interaction {
        let network = group.network
        let link = try await group.suggest(.change(time: Fixtures.later, activity: nil, adding: nil), by: Fixtures.alex)
        await network.deliver()
        try await network.until("cards up") {
            for person in [Fixtures.maya, Fixtures.jake] where await group.openCard(of: person) == nil { return false }
            return true
        }
        for person in [Fixtures.maya, Fixtures.jake] {
            try await group.phone(person).service.answer(try await group.card(of: person).id, with: .accept(proposal: 1))
        }
        // Only now, so the yeses themselves go through.
        for (frame, skipping) in frames { network.drop(frame, skipping: skipping) }
        await network.deliver()
        return link
    }

    /// Moves the clock on by `seconds` and waits for `phone` to send `count`
    /// more frames, then delivers everything.
    static func resend(_ group: Group, after seconds: TimeInterval, from phone: Phone, count: Int = 1) async throws {
        let before = await phone.transport.sent.count
        group.clock.advance(to: group.clock.now.addingTimeInterval(seconds))
        try await group.network.until("resent") { await phone.transport.sent.count >= before + count }
        await group.network.deliver()
    }

    static func revisions(_ group: Group, _ people: [PeerID]) async -> [UInt32?] {
        var all: [UInt32?] = []
        for person in people { all.append(await group.phone(person).plan(group.origin)?.revision) }
        return all
    }

    @Test func aLostConfirmationAndThenALostAcknowledgmentStillEndOnOneRevision() async throws {
        let group = Group()
        let network = group.network
        // Jake's confirmation is lost.
        try await Self.agreed(group, losing: [("Alex > Jake: accept", skipping: 0)])
        try await network.until("Alex and Maya applied") {
            await Self.revisions(group, [alex, maya]) == [1, 1]
        }
        await network.settle()
        #expect(await group.phone(jake).plan(group.origin)?.revision == 0)

        // Resent after the first wait; this time Jake's acknowledgment is lost.
        network.drop("Jake > Alex: accept")
        try await Self.resend(group, after: 5, from: group.phone(alex))
        try await network.until("Jake applied") { await group.phone(jake).plan(group.origin)?.revision == 1 }

        // Resent again; Jake acknowledges again and changes nothing.
        try await Self.resend(group, after: 10, from: group.phone(alex))
        await network.settle()
        #expect(await Self.revisions(group, [alex, maya, jake]) == [1, 1, 1])
        for person in [alex, maya, jake] { #expect(await group.phone(person).plan(group.origin)?.time == Fixtures.later) }
        #expect(network.transcript.suffix(5) == [
            "Maya > Alex: accept", "Alex > Jake: accept", "Jake > Alex: accept (lost)",
            "Alex > Jake: accept", "Jake > Alex: accept",
        ])
        // Everyone acknowledged: nothing more is sent, and nothing is left owed.
        let sent = await group.phone(alex).transport.sent.count
        group.clock.advance(to: group.clock.now.addingTimeInterval(600))
        await network.settle()
        #expect(await group.phone(alex).transport.sent.count == sent)
        #expect(try await group.phone(alex).journal.records().allSatisfy { if case .confirming = $0 { false } else { true } })
        // The duplicate confirmation broke no lifecycle rule anywhere.
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aLeaveNoticeLostOnceStillShrinksEveryPlan() async throws {
        let group = Group()
        let network = group.network
        network.drop("Jake > Maya: reject")
        try await group.suggest(.leave, by: jake)
        await network.deliver()
        try await network.until("Alex's plan shrank") { await group.phone(alex).plan(group.origin)?.attendees.peers == [alex, maya] }
        #expect(await group.phone(maya).plan(group.origin)?.attendees.peers == [alex, maya, jake])

        // Resent, in a fresh conversation, to Maya alone; her acknowledgment is lost.
        network.drop("Maya > Jake: accept")
        try await Self.resend(group, after: 5, from: group.phone(jake))
        try await network.until("Maya's plan shrank") { await group.phone(maya).plan(group.origin)?.attendees.peers == [alex, maya] }
        let entries = await group.phone(maya).changes().count

        // Resent again: Maya acknowledges, and applies nothing twice.
        try await Self.resend(group, after: 10, from: group.phone(jake))
        await network.settle()
        #expect(await group.phone(maya).changes().count == entries)
        #expect(await Self.revisions(group, [alex, maya]) == [1, 1])
        #expect(network.transcript == [
            "Jake > Alex: reject", "Jake > Maya: reject (lost)", "Alex > Jake: accept",
            "Jake > Maya: reject", "Maya > Jake: accept (lost)",
            "Jake > Maya: reject", "Maya > Jake: accept",
        ])
        // Then Jake owes nothing more.
        let sent = await group.phone(jake).transport.sent.count
        group.clock.advance(to: group.clock.now.addingTimeInterval(600))
        await network.settle()
        #expect(await group.phone(jake).transport.sent.count == sent)
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aConfirmationOwedSurvivesTheSuggestersRestart() async throws {
        let group = Group()
        let network = group.network
        try await Self.agreed(group, losing: [("Alex > Jake: accept", skipping: 0)])
        try await network.until("Maya applied") { await group.phone(maya).plan(group.origin)?.revision == 1 }
        // Alex's app quits and relaunches: the confirmation still owed to
        // Jake comes back from the journal and goes out again at once.
        await group.phone(alex).restart()
        await network.deliver()
        try await network.until("Jake applied") { await group.phone(jake).plan(group.origin)?.revision == 1 }
        try await network.until("Alex's delivery done") {
            (try? await group.phone(alex).journal.records().isEmpty) == true
        }
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }

    @Test func aRestartedFriendStillAcknowledgesAResentConfirmation() async throws {
        let group = Group()
        let network = group.network
        // Jake applies, but his acknowledgment (after his yes) is lost.
        try await Self.agreed(group, losing: [("Jake > Alex: accept", skipping: 1)])
        try await network.until("all applied") { await Self.revisions(group, [alex, maya, jake]) == [1, 1, 1] }
        // Jake's app relaunches; what he applied comes back from his journal.
        await group.phone(jake).restart()
        try await Self.resend(group, after: 5, from: group.phone(alex))
        try await network.until("Alex's delivery done") {
            (try? await group.phone(alex).journal.records().isEmpty) == true
        }
        #expect(await Self.revisions(group, [alex, maya, jake]) == [1, 1, 1])
        #expect(network.transcript.suffix(2) == ["Alex > Jake: accept", "Jake > Alex: accept"])
        #expect(await network.problems().isEmpty)
        await network.shutdown()
    }
}
