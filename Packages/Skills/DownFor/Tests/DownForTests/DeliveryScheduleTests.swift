import Foundation
@testable import DownFor
import StarlingCore
import StarlingFakes
import Testing

/// The fixed delivery schedule of a starter's proposal (ADR 0210 decision
/// 13), on virtual time.
@Suite(.timeLimit(.minutes(1))) struct DeliveryScheduleTests {
    /// Lane F's #76. Proposals are due at 0, 100, 300, and 700 ms within a
    /// 1,490 ms window. The third send is held in the policy past 700 ms, so
    /// the last one waits behind it on the friend's queue. When the held
    /// send goes, the last one must follow: the schedule keeps it until it
    /// has been sent, while the request is still live.
    @Test func theLastScheduledSendSurvivesAnEarlierSendStillInFlight() async throws {
        let time = VirtualTime()
        let policy = HoldsAProposal(number: 3)
        let configuration = DownForConfiguration(
            retryInterval: .milliseconds(100), maxAttempts: 100, ownerWindow: .milliseconds(1_490), maxBackoff: .seconds(1)
        )
        let world = World(2, policy: policy, clock: time.clock(now: T.now), configuration: configuration)
        let (a, b) = (world["A"], world["B"])
        await policy.watch(a.id)
        try await world.start()
        defer { Task { await world.stop() } }

        let mine = try await a.down(for: ["boba"], with: [b])
        let theirs = try await b.down(for: ["boba"], with: [a])
        try await a.waitForProposal(mine)
        try await b.waitForProposal(theirs)
        @Sendable func proposals() async -> Int { await world.wire.envelopes.filter { $0.sender == a.id && $0.body.kind == .propose }.count }
        #expect(DownForService.deliverySchedule(window: configuration.ownerWindow, first: configuration.retryInterval, cap: configuration.maxBackoff)
            == [0, 100, 300, 700].map { .milliseconds($0) })
        try await eventually("the first proposal") { await proposals() == 1 }
        // The whole schedule is set from the start.
        try await eventually("the schedule") { Set(await time.due).isSuperset(of: [100, 300, 700].map { .milliseconds($0) }) }

        // 100 ms: the second. 300 ms: the third, held in the policy.
        await time.advance(to: .milliseconds(100))
        try await eventually("the second proposal") { await proposals() == 2 }
        await time.advance(to: .milliseconds(300))
        try await eventually("the third proposal held") { await policy.holding }

        // 700 ms: the last is due and queued behind the held send.
        await time.advance(to: .milliseconds(700))
        try await Task.sleep(for: .milliseconds(50))
        #expect(await a.lifecycle.state(mine) == .proposed)

        // Release it, still inside the window: the last send follows.
        await policy.release()
        try await eventually("all four proposals") { await proposals() == 4 }
        #expect(await a.lifecycle.state(mine) == .proposed)
        await world.expectCleanLifecycles()
    }
}

/// Holds one starter's `number`th proposal in the policy until released,
/// then allows it. Everything else is allowed at once. The Outbox checks a
/// send twice (again after consent), so sends are counted by envelope.
actor HoldsAProposal: PolicyEngine {
    let number: Int
    private var sender: PeerID?
    private var seen: [MessageID] = []
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var holding = false

    init(number: Int) { self.number = number }

    func watch(_ peer: PeerID) { sender = peer }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }

    func evaluate(_ message: OutboundMessage) async -> PolicyDecision {
        guard message.envelope.sender == sender, message.envelope.body.kind == .propose else { return .allow }
        if !seen.contains(message.envelope.id) { seen.append(message.envelope.id) }
        guard seen.firstIndex(of: message.envelope.id) == number - 1, !released else { return .allow }
        holding = true
        await withCheckedContinuation { waiting = $0 }
        holding = false
        return .allow
    }
}
