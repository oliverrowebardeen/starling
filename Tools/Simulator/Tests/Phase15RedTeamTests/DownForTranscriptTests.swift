import DownFor
import Foundation
import SimulatorKit
import StarlingCore
import Testing

@Suite("P15-F Down for privacy transcripts", .serialized)
struct DownForTranscriptTests {
    struct Schedule: Equatable {
        let kinds: [MessageBody.Kind]
        let offers: [Terms]
    }

    @Test func aStartersPassAndSilencePreserveTheScheduleBeforeItsFinalResend() async throws {
        let passed = try await schedule(pass: true, otherFriend: false)
        let silent = try await schedule(pass: false, otherFriend: false)
        #expect(passed == silent)
        #expect(passed.kinds == Array(repeating: .propose, count: 4))
    }

    @Test func anotherFriendsInterestAndPassPreserveTheScheduleBeforeItsFinalResend() async throws {
        let absent = try await schedule(pass: false, otherFriend: false)
        let present = try await schedule(pass: false, otherFriend: true)
        #expect(absent == present)
    }

    func schedule(pass: Bool, otherFriend: Bool) async throws -> Schedule {
        let world = try await DownWorld.make(configuration: DownPhone.transcriptConfiguration)
        defer { Task { await world.stop() } }
        let (a, b, c) = (world.phones[0], world.phones[1], world.phones[2])
        let aToC = try await a.start(with: [c.id])
        var cToA: Interaction?
        if otherFriend { cToA = try await c.start(with: [a.id]) }
        let (mine, _) = try await world.pair(a, b)
        try await Simulation.eventually("first pair proposal settled") { await a.sent(mine.conversation).contains { $0.body.kind == .propose } }
        let first = try #require(await a.wire.records.first { $0.envelope.conversation == mine.conversation && $0.envelope.body.kind == .propose })
        if pass { try await a.service.answer(mine.id, with: .pass) }
        if let cToA {
            _ = try await c.wait(.proposed, cToA)
            try await c.service.answer(cToA.id, with: .pass)
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(try await a.events.store.interaction(mine.id)?.state == .proposed)
        #expect(try await !a.phone.conversations.isRetired(mine.conversation))
        _ = try await a.wait(.ended(pass ? .declined : .expired), mine)
        #expect(try await a.phone.conversations.isRetired(mine.conversation))
        // Issue #76's final queued resend has a separate suspended-send reproduction.
        // Compare the stable prefix here; do not claim the tail count passes.
        let trace = Array(await a.wire.records.filter { $0.envelope.conversation == mine.conversation && $0.envelope.body.kind == .propose }.prefix(4))
        let expected: [Duration] = [.zero, .milliseconds(150), .milliseconds(450), .milliseconds(750)]
        #expect(trace.count == expected.count)
        for (record, target) in zip(trace, expected) {
            let actual = first.at.duration(to: record.at)
            #expect(actual >= max(.zero, target - .milliseconds(100)))
            #expect(actual <= target + .milliseconds(500))
        }
        #expect(await a.sent(mine.conversation).allSatisfy { $0.recipient == b.id })
        #expect(await a.sent(aToC.conversation).allSatisfy { $0.recipient == c.id })
        let offers = trace.compactMap { if case .propose(let p) = $0.envelope.body { p.terms } else { nil } }
        #expect(offers.allSatisfy { $0[.people] == nil })
        return Schedule(kinds: trace.map { $0.envelope.body.kind }, offers: offers)
    }

    @Test func aMembersPassAndAnUntouchedCardGiveTheSameProbeTranscript() async throws {
        let passed = try await memberProbe(pass: true)
        let silent = try await memberProbe(pass: false)
        #expect(passed == silent && passed.isEmpty)
    }

    func memberProbe(pass: Bool) async throws -> [MessageBody.Kind] {
        let world = try await DownWorld.make(2)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        let (mine, theirs) = try await world.pair(a, b)
        let query = try #require(await a.sent(mine.conversation).first { $0.body.kind == .query })
        if pass {
            try await b.service.answer(theirs.id, with: .pass)
            _ = try await b.wait(.ended(.declined), theirs)
        }
        let before = await b.sent(mine.conversation).count
        let replay = try await a.send(query.body, to: b.id, in: mine.conversation)
        try await world.delivered(replay, to: b)
        let freshPSI = try await a.openPSI(to: b.id, conversation: mine.conversation).0
        try await world.delivered(freshPSI, to: b)
        let other = try await a.openPSI(to: b.id).0
        try await world.delivered(other, to: b)
        #expect(await b.sent(other.conversation).isEmpty)
        return await b.sent(mine.conversation).dropFirst(before).map(\.body.kind)
    }

    @Test func theFinalScheduledResendSurvivesAnEarlierSendStillInFlight() async throws {
        // Four sends are due at 0, 0.1, 0.3, and 0.7 seconds. The owner
        // window stays open until 1.49, so releasing at about 0.9 is in time.
        let configuration = DownForConfiguration(retryInterval: .milliseconds(100), maxAttempts: 30,
            ownerWindow: .milliseconds(1490), maxBackoff: .seconds(1))
        let world = try await DownWorld.make(2, configuration: configuration)
        defer { Task { await world.stop() } }
        let (a, b) = (world.phones[0], world.phones[1])
        await a.wire.holdProposal(3)
        let (mine, _) = try await world.pair(a, b)
        try await Simulation.eventually("third proposal held before transport") { await a.wire.holding }
        try await Task.sleep(for: .milliseconds(600))
        #expect(try await a.events.store.interaction(mine.id)?.state == .proposed)
        await a.wire.release()
        _ = try await a.wait(.ended(.expired), mine)
        let proposals = await b.phone.agent.received.filter { $0.conversation == mine.conversation && $0.body.kind == .propose }
        #expect(proposals.count == 4)
    }
}
