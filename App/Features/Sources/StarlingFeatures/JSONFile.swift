import Foundation

/// One Codable value in one JSON file, written atomically, excluded from
/// backups, and protected until first unlock: the class ADR 0003 uses for
/// keys, which still lets the app read it in the background (ADR 0200).
/// Not synchronized: each owner is an actor that serializes its own reads
/// and writes.
public struct JSONFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `Application Support/Starling/<name>`.
    public static func standard(_ name: String) throws -> JSONFile {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "Starling", directoryHint: .isDirectory)
        return JSONFile(url: directory.appending(path: name))
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    /// The stored value, or nil if nothing has been written yet. Throws if
    /// the file exists but cannot be read or decoded.
    public func read<Value: Decodable>(_ type: Value.Type) throws -> Value? {
        guard exists else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    public func write<Value: Encodable>(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: options)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(excluded)
    }

    /// Moves an unreadable file aside, so a later write never overwrites
    /// what could still be recovered by hand. Returns where it went.
    @discardableResult
    public func quarantine(now: Date = Date()) throws -> URL {
        let stamp = Int(now.timeIntervalSince1970)
        let name = url.deletingPathExtension().lastPathComponent
        let aside = url.deletingLastPathComponent().appending(path: "\(name).unreadable-\(stamp).\(url.pathExtension)")
        try FileManager.default.moveItem(at: url, to: aside)
        return aside
    }
}
