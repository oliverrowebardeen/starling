import Foundation
import StarlingCore

/// A `DownService` that records intents and emits whatever events a test or
/// preview pushes with `emit`.
public actor ScriptedDownService: DownService {
    public nonisolated let events: AsyncStream<DownEvent>
    private let continuation: AsyncStream<DownEvent>.Continuation
    public private(set) var intents: [DownIntent] = []
    public private(set) var cleared = 0
    public private(set) var handled: [InboxEvent] = []

    public init() {
        (events, continuation) = AsyncStream.makeStream(of: DownEvent.self)
    }

    public func setIntent(_ intent: DownIntent) async throws { intents.append(intent) }

    public func clearIntent() async { cleared += 1 }

    public func handle(_ event: InboxEvent) async { handled.append(event) }

    public nonisolated func emit(_ event: DownEvent) { continuation.yield(event) }
}
