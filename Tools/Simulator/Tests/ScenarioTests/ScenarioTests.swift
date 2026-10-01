import Foundation
import Scenarios
import StarlingCore
import Testing

/// Adversarial and flow scenarios. Owned by the red team lane.
@Suite struct ScenarioTests {
    @Test func helloMeshDeliversEveryCard() async throws {
        let outcome = try await ScenarioRunner.run(.helloMesh, agents: 6)
        #expect(outcome.accepted.filter { $0.body.kind == .hello }.count == 6 * 5)
    }

    @Test func proposeAcceptCompletes() async throws {
        let outcome = try await ScenarioRunner.run(.proposeAccept)
        #expect(outcome.accepted.contains { $0.body.kind == .accept })
    }

    @Test func replayedFramesAreDropped() async throws {
        let outcome = try await ScenarioRunner.run(.replay)
        #expect(outcome.dropped == [.replay])
        #expect(outcome.accepted.filter { $0.body.kind == .propose }.count == 1)
    }

    @Test func reorderedFramesAreDeliveredOnce() async throws {
        let outcome = try await ScenarioRunner.run(.reorder)
        #expect(outcome.accepted.map(\.sequence) == [2, 0, 1])
        #expect(outcome.dropped == [.replay])
    }

    @Test func replayWindowHandlesBoundariesWithoutOverflow() async throws {
        let outcome = try await ScenarioRunner.run(.replayWindow)
        #expect(outcome.accepted.map(\.sequence) == [64, 1, UInt64.max, UInt64.max - 63])
        #expect(outcome.dropped == Array(repeating: .replay, count: 4))
    }

    @Test func staleFramesDoNotPoisonReplayState() async throws {
        let outcome = try await ScenarioRunner.run(.stale)
        #expect(outcome.accepted.map(\.sequence) == [0, 1])
        #expect(outcome.dropped == [.stale, .stale])
    }

    @Test func futureFramesDoNotPoisonReplayState() async throws {
        let outcome = try await ScenarioRunner.run(.futureDated)
        #expect(outcome.accepted.map(\.sequence) == [0, 1])
        #expect(outcome.dropped == [.fromFuture, .fromFuture])
    }

    @Test func relayedEnvelopesWithMismatchedSendersAreDropped() async throws {
        let outcome = try await ScenarioRunner.run(.senderMismatch)
        #expect(outcome.dropped == [.senderMismatch])
    }

    @Test func garbageIsDropped() async throws {
        let outcome = try await ScenarioRunner.run(.garbage)
        #expect(outcome.dropped.count == 1)
        #expect(outcome.accepted.allSatisfy { $0.body.kind == .hello })
    }

    /// Phase 0 has no authentication, so a peer that forges both the envelope
    /// sender and the link identity is accepted. The Phase 1 secure channel
    /// (ADR 0003) must fix this; when it does, this known issue stops
    /// reproducing and the test fails until the marker is removed.
    @Test func impersonationIsAKnownPhase0Gap() async throws {
        let outcome = try await ScenarioRunner.run(.impersonation)
        withKnownIssue("https://github.com/oliverrowebardeen/starling-ios/issues/8") {
            #expect(outcome.accepted.allSatisfy { $0.body.kind == .hello })
        }
    }
}
