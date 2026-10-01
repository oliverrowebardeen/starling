import Foundation
import StarlingCore
import StarlingFakes
import StarlingFeatures
import Testing

/// A DownService whose setIntent waits until the test releases it, so events
/// can arrive while it is in flight (lane F may start checking before
/// setIntent returns).
actor GatedDownService: DownService {
    nonisolated let events: AsyncStream<DownEvent>
    private let continuation: AsyncStream<DownEvent>.Continuation
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    init() {
        (events, continuation) = AsyncStream.makeStream(of: DownEvent.self)
    }

    func setIntent(_ intent: DownIntent) async throws {
        isWaiting = true
        await withCheckedContinuation { gate = $0 }
        isWaiting = false
    }

    func clearIntent() async {}
    func handle(_ event: InboxEvent) async {}

    nonisolated func emit(_ event: DownEvent) { continuation.yield(event) }

    func release() {
        gate?.resume()
        gate = nil
    }
}

/// Review finding 4 on PR #15: events delivered while setIntent is in
/// flight must not be lost or overwritten when it returns.
@MainActor
@Suite struct DownInFlightTests {
    let service = GatedDownService()
    let maya = Fixtures.peer("Maya")

    func model() -> DownModel {
        let model = DownModel(
            service: service,
            interpreter: RulesInterpreter(agent: nil, issues: RulesInterpreter.intentIssues),
            rules: InMemoryRulesStore(),
            peers: InMemoryPairedPeerStore([maya]),
            notifier: RecordingNotifier(),
            noMatchHold: .seconds(10)
        )
        model.listen()
        return model
    }

    /// Starts goDown and returns once setIntent is waiting.
    func goDownInFlight(_ model: DownModel) async -> Task<Void, Never> {
        await model.editByHand()
        let going = Task { await model.goDown() }
        for _ in 0..<2000 where !(await service.isWaiting) { try? await Task.sleep(for: .milliseconds(1)) }
        return going
    }

    @Test func aCheckingCountDuringSetIntentIsKept() async {
        let model = model()
        let going = await goDownInFlight(model)
        service.emit(.checking(friends: 3))
        await eventually { model.active?.checkingFriends == 3 }
        await service.release()
        await going.value
        #expect(model.phase == .active)
        #expect(model.active?.checkingFriends == 3)
    }

    @Test func aMatchDuringSetIntentIsKept() async {
        let model = model()
        let going = await goDownInFlight(model)
        service.emit(.matched(DownMatch(peer: maya.id, terms: .empty, bothDown: true)))
        await eventually { !model.matches.isEmpty }
        await service.release()
        await going.value
        #expect(model.matches.map(\.friendName) == ["Maya"])
        #expect(model.status == .match)
        #expect(model.phase == .active)
    }

    @Test func anEndDuringSetIntentIsNotOverwritten() async {
        let model = model()
        let going = await goDownInFlight(model)
        service.emit(.ended(.failed))
        await eventually { model.phase == .composing }
        await service.release()
        await going.value
        #expect(model.phase == .composing)
        #expect(model.active == nil)
        #expect(model.status == .noMatch)
    }
}
