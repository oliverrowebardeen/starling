import Foundation
import StarlingCore
import Synchronization

/// What the model already answered for words it read, so New can read the
/// owner's draft as often as it likes (lane A reads it as the owner types):
/// the same words cost no model call the second time and give the same
/// chips (device test 2, 2026-10-02). Words count as the same when they
/// differ only in spacing.
///
/// Only the model's raw answer is kept. Code's checks run again on every
/// read, against the words as typed and the current time, so a cached
/// answer is never applied to other words or a stale clock.
package final class SkillReadCache: Sendable {
    /// The most recent drafts kept, per kind of answer.
    static let capacity = 64

    private struct Entries<Value: Sendable>: Sendable {
        var values: [String: Value] = [:]
        var order: [String] = []

        mutating func insert(_ value: Value, for key: String) {
            if values.updateValue(value, forKey: key) == nil { order.append(key) }
            while order.count > SkillReadCache.capacity { values[order.removeFirst()] = nil }
        }
    }

    private let routes = Mutex(Entries<SkillID?>())
    private let intents = Mutex(Entries<RawIntent>())

    package init() {}

    /// The words with spacing made uniform: what makes two drafts the same.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func routeKey(_ text: String, skills: [SkillDescriptor]) -> String {
        skills.map { "\($0.ref)" }.joined(separator: ",") + "\n" + normalized(text)
    }

    static func intentKey(_ text: String, skill: SkillDescriptor) -> String {
        "\(skill.ref)\n" + normalized(text)
    }

    /// `.some(nil)` is a cached answer of no skill.
    package func route(for key: String) -> SkillID?? { routes.withLock { $0.values[key] } }
    package func remember(route: SkillID?, for key: String) { routes.withLock { $0.insert(route, for: key) } }
    package func intent(for key: String) -> RawIntent? { intents.withLock { $0.values[key] } }
    package func remember(intent: RawIntent, for key: String) { intents.withLock { $0.insert(intent, for: key) } }
}
