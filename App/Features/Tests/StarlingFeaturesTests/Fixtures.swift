import Foundation
import StarlingCore
import StarlingFeatures

enum Fixtures {
    static let noon = Date(timeIntervalSince1970: 1_790_000_000)
    static let utc = TimeZone(identifier: "UTC")!

    static let budgetRules = OwnerRules(
        constraints: try! ConstraintSet([.budget: [try! Constraint(.atMost(try! MoneyAmount(minorUnits: 1500)))]]),
        disclosure: [DisclosureRule(issue: .place, action: .never)]
    )

    static func peer(_ nickname: String, pairedAt: Int64 = 0) -> PairedPeer {
        var generator = SystemRandomNumberGenerator()
        let key = try! IdentityPublicKey(bytes: Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) }))
        return try! PairedPeer(publicKey: key, nickname: nickname, pairedAt: Timestamp(millisecondsSince1970: pairedAt))
    }
}

/// Collects values from `@Sendable` closures under test.
actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func record(_ value: Value) { values.append(value) }
}

/// Polls until `condition` holds, for up to 30 s of the host's awake time.
/// Models consume event streams on their own tasks, so tests wait for those
/// tasks to catch up. `SuspendingClock` stops while the host sleeps, so a
/// sleep mid-run does not use up the wait (ADR 0258). The bound only
/// matters when the condition never holds, and the condition is checked
/// once more at the deadline.
@MainActor
func eventually(_ condition: () -> Bool) async {
    let clock = SuspendingClock()
    let deadline = clock.now + .seconds(30)
    while !condition(), clock.now < deadline, !Task.isCancelled {
        try? await clock.sleep(for: .milliseconds(1))
    }
}

/// `eventually` for a condition that awaits, from any isolation.
func waitUntil(isolation: isolated (any Actor)? = #isolation, _ condition: () async throws -> Bool) async rethrows {
    let clock = SuspendingClock()
    let deadline = clock.now + .seconds(30)
    while try await !condition(), clock.now < deadline, !Task.isCancelled {
        try? await clock.sleep(for: .milliseconds(1))
    }
}

actor RecordingNotifier: PlanNotifier {
    private(set) var posted: [LifecycleNotice] = []
    private(set) var authorizationRequests = 0
    let allow: Bool
    private var state: NotificationAccess

    init(allow: Bool = true, access: NotificationAccess = .notAsked) {
        self.allow = allow
        state = access
    }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        state = allow ? .allowed : .denied
        return allow
    }

    func access() async -> NotificationAccess { state }

    func post(_ notice: LifecycleNotice) async { posted.append(notice) }
}

actor CountingPrompter: LocalNetworkPrompter {
    private(set) var prompts = 0
    func prompt() async { prompts += 1 }
}
