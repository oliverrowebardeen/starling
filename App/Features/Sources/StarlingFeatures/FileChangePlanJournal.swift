import Foundation
import StarlingChangePlan
import StarlingCore

/// Lane E's `ChangePlanJournal` on the phone (P15-E request 10, ADR 0243),
/// in `Application Support/Starling/change-plan-journal.json`: the
/// confirmations and leave notices still owed an acknowledgment, and what
/// this phone applied, so a restart keeps resending and never applies a
/// change twice.
///
/// Every save and remove is written before it returns and throws when it
/// cannot be. A file that exists but cannot be read throws rather than
/// reading as nothing owed. The cache changes only after a write succeeds.
public actor FileChangePlanJournal: ChangePlanJournal {
    public struct Unreadable: Error, Hashable, Sendable {}

    struct Document: Codable {
        var version = 1
        var records: [ChangePlanRecord] = []
    }

    private let file: JSONFile
    private var cache: [ChangePlanRecord]?

    public init(file: JSONFile) {
        self.file = file
    }

    public static func standard() throws -> FileChangePlanJournal {
        FileChangePlanJournal(file: try .standard("change-plan-journal.json"))
    }

    public func save(_ record: ChangePlanRecord) async throws {
        var next = try loaded()
        if let index = next.firstIndex(where: { $0.key == record.key }) { next[index] = record } else { next.append(record) }
        try commit(next)
    }

    public func remove(_ key: UUID) async throws {
        var next = try loaded()
        guard next.contains(where: { $0.key == key }) else { return }
        next.removeAll { $0.key == key }
        try commit(next)
    }

    public func records() async throws -> [ChangePlanRecord] {
        try loaded()
    }

    private func loaded() throws -> [ChangePlanRecord] {
        if let cache { return cache }
        do {
            let records = try file.read(Document.self)?.records ?? []
            cache = records
            return records
        } catch {
            throw Unreadable()
        }
    }

    private func commit(_ records: [ChangePlanRecord]) throws {
        try file.write(Document(records: records))
        cache = records
    }
}

/// Stands in when the journal's file cannot even be located: every call
/// throws, so nothing is confirmed that could not be resent after a restart.
public struct UnavailableChangePlanJournal: ChangePlanJournal {
    public struct Unavailable: Error {}
    public init() {}
    public func save(_ record: ChangePlanRecord) async throws { throw Unavailable() }
    public func remove(_ key: UUID) async throws { throw Unavailable() }
    public func records() async throws -> [ChangePlanRecord] { throw Unavailable() }
}
