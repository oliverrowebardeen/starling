import Foundation
import StarlingCore
import StarlingFeatures
import Testing

@Suite struct FileRulesStoreTests {
    @Test func savesAndLoadsRules() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "starling-\(UUID().uuidString)/rules.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileRulesStore(url: url)
        #expect(try await store.load() == nil)
        let rules = SavedRules(rules: Fixtures.budgetRules, savedAt: Date(timeIntervalSince1970: 1_790_000_000))
        try await store.save(rules)
        #expect(try await FileRulesStore(url: url).load() == rules)
    }
}
