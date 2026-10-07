import SimulatorKit

/// Host scheduling waits count time while the Mac is awake. Protocol time
/// still belongs to each service's injected clock.
public enum AwakeWait {
    public static func eventually(
        timeout: Duration = .seconds(30),
        polling: Duration = .milliseconds(5),
        _ description: String,
        isolation: isolated (any Actor)? = #isolation,
        _ condition: () async throws -> Bool
    ) async throws {
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if try await condition() { return }
            guard clock.now < deadline else { throw SimulationError.timedOut(description) }
            try await clock.sleep(for: polling)
        }
    }

    public static func mesh(_ simulation: Simulation, timeout: Duration = .seconds(30)) async throws {
        let agents = await simulation.agents
        try await eventually(timeout: timeout, "mesh of \(agents.count)") {
            for agent in agents where await agent.peerCards.count < agents.count - 1 { return false }
            return true
        }
    }
}
