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

/// Polls until `condition` holds or two seconds pass. Models consume event
/// streams on their own tasks, so tests wait for those tasks to catch up.
@MainActor
func eventually(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

actor RecordingNotifier: PlanNotifier {
    private(set) var posted: [LifecycleNotice] = []
    private(set) var authorizationRequests = 0
    let allow: Bool

    init(allow: Bool = true) { self.allow = allow }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return allow
    }

    func post(_ notice: LifecycleNotice) async { posted.append(notice) }
}

actor CountingPrompter: LocalNetworkPrompter {
    private(set) var prompts = 0
    func prompt() async { prompts += 1 }
}
