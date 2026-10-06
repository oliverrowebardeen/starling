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

    /// Regression: #8
    @Test func impersonationIsDroppedBeforeTheInbox() async throws {
        let outcome = try await ScenarioRunner.run(.impersonation)
        #expect(!outcome.accepted.contains { $0.body.kind == .reject })
        #expect(outcome.dropped.isEmpty)
        #expect(outcome.secureDroppedFrames == 1)
        #expect(outcome.accepted.count == 2)
        let genuine = try #require(outcome.accepted.first { $0.body.kind == .propose })
        #expect(outcome.accepted.filter { $0.body.kind == .propose }.count == 1)
        #expect(outcome.provenPeer == genuine.sender)
    }
}
