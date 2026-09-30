import Foundation
import StarlingCore

/// The owner's reviewed standing rules. Stored on the device only; no
/// `MessageBody` can carry `OwnerRules`.
public struct SavedRules: Hashable, Sendable, Codable {
    public let rules: OwnerRules
    public let savedAt: Date

    public init(rules: OwnerRules, savedAt: Date) {
        self.rules = rules
        self.savedAt = savedAt
    }
}

public protocol RulesStore: Sendable {
    func load() async throws -> SavedRules?
    func save(_ rules: SavedRules) async throws
}

/// Keeps rules in a JSON file in Application Support, excluded from backups
/// and protected until first unlock, the same class ADR 0003 uses for keys.
public actor FileRulesStore: RulesStore {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `Application Support/Starling/rules.json`.
    public static func standard() throws -> FileRulesStore {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Starling", directoryHint: .isDirectory)
        return FileRulesStore(url: directory.appending(path: "rules.json"))
    }

    public func load() async throws -> SavedRules? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try JSONDecoder().decode(SavedRules.self, from: Data(contentsOf: url))
    }

    public func save(_ rules: SavedRules) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try JSONEncoder().encode(rules).write(to: url, options: options)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(excluded)
    }
}

/// Rules held in memory, for previews and tests.
public actor InMemoryRulesStore: RulesStore {
    public private(set) var saved: SavedRules?

    public init(_ saved: SavedRules? = nil) {
        self.saved = saved
    }

    public func load() async throws -> SavedRules? { saved }
    public func save(_ rules: SavedRules) async throws { saved = rules }
}
