import Foundation
import StarlingCore

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
