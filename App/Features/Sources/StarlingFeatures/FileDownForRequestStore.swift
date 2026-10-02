import DownFor
import Foundation
import StarlingCore

/// Lane B's `DownForRequestStore` on the phone (P15-B request 2), in
/// `Application Support/Starling/down-for-requests.json` with the same file
/// protection as the interaction store (ADR 0200's helper), because each
/// record holds the owner's rules for a request. A restart keeps every
/// request the service still runs, so it can restore them.
///
/// Every change is written before it returns and throws when it cannot be.
/// A file that exists but cannot be read throws, rather than reading as no
/// requests. The cache changes only after a write succeeds.
public actor FileDownForRequestStore: DownForRequestStore {
    public struct Unreadable: Error, Hashable, Sendable {}

    struct Document: Codable {
        var version = 1
        var records: [DownForRequestRecord] = []
    }

    private let file: JSONFile
    private var cache: [InteractionID: DownForRequestRecord]?

    public init(file: JSONFile) {
        self.file = file
    }

    public static func standard() throws -> FileDownForRequestStore {
        FileDownForRequestStore(file: try .standard("down-for-requests.json"))
    }

    public func save(_ record: DownForRequestRecord) async throws {
        var next = try loaded()
        next[record.interaction] = record
        try commit(next)
    }

    public func record(for interaction: InteractionID) async throws -> DownForRequestRecord? {
        try loaded()[interaction]
    }

    public func remove(_ interaction: InteractionID) async throws {
        var next = try loaded()
        guard next.removeValue(forKey: interaction) != nil else { return }
        try commit(next)
    }

    private func loaded() throws -> [InteractionID: DownForRequestRecord] {
        if let cache { return cache }
        do {
            let records = try file.read(Document.self)?.records ?? []
            let byID = Dictionary(records.map { ($0.interaction, $0) }) { _, latest in latest }
            cache = byID
            return byID
        } catch {
            throw Unreadable()
        }
    }

    private func commit(_ records: [InteractionID: DownForRequestRecord]) throws {
        try file.write(Document(records: records.values.sorted { $0.interaction.description < $1.interaction.description }))
        cache = records
    }
}
