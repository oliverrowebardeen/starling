import Foundation
import StarlingCore

/// The app's `InteractionStore` (ADR 0011 decision 6, ADR 0200): every
/// interaction in one JSON file, cached in memory and written through on
/// each change.
///
/// - Live interactions are always kept. Finished ones (done or ended) are
///   history for Friends and plan timelines; only the newest
///   `maxFinished` are kept, so the file stays small.
/// - An unreadable file is moved aside, never overwritten, and the store
///   starts empty. `quarantined` says where it went so the app can tell
///   the owner.
public actor FileInteractionStore: InteractionStore {
    public static let maxFinished = 500

    /// The file's shape, versioned so a later build can migrate it.
    struct Document: Codable {
        var version = 1
        var interactions: [Interaction]
    }

    private let file: JSONFile
    private let maxFinished: Int
    private var cache: [InteractionID: Interaction]?
    public private(set) var quarantined: URL?

    public init(file: JSONFile, maxFinished: Int = FileInteractionStore.maxFinished) {
        self.file = file
        self.maxFinished = maxFinished
    }

    /// `Application Support/Starling/interactions.json`.
    public static func standard() throws -> FileInteractionStore {
        FileInteractionStore(file: try .standard("interactions.json"))
    }

    public func all() async throws -> [Interaction] {
        try loaded().values.sorted { ($0.createdAt, $0.id.rawValue.uuidString) < ($1.createdAt, $1.id.rawValue.uuidString) }
    }

    public func interaction(_ id: InteractionID) async throws -> Interaction? {
        try loaded()[id]
    }

    public func interaction(conversation: ConversationID) async throws -> Interaction? {
        try loaded().values.first { $0.conversation == conversation }
    }

    public func save(_ interaction: Interaction) async throws {
        var items = try loaded()
        items[interaction.id] = interaction
        prune(&items)
        try persist(items)
    }

    public func remove(_ id: InteractionID) async throws {
        var items = try loaded()
        guard items.removeValue(forKey: id) != nil else { return }
        try persist(items)
    }

    private func loaded() throws -> [InteractionID: Interaction] {
        if let cache { return cache }
        var items: [InteractionID: Interaction] = [:]
        do {
            for item in try file.read(Document.self)?.interactions ?? [] { items[item.id] = item }
        } catch {
            quarantined = try file.quarantine()
            items = [:]
        }
        cache = items
        return items
    }

    /// Drops the oldest finished interactions beyond `maxFinished`.
    private func prune(_ items: inout [InteractionID: Interaction]) {
        let finished = items.values.filter(\.state.isFinal)
        guard finished.count > maxFinished else { return }
        for old in finished.sorted(by: { $0.updatedAt < $1.updatedAt }).prefix(finished.count - maxFinished) {
            items[old.id] = nil
        }
    }

    /// Writes first, then updates the cache, so a failed write leaves the
    /// cache matching the file.
    private func persist(_ items: [InteractionID: Interaction]) throws {
        try file.write(Document(interactions: items.values.sorted { $0.createdAt < $1.createdAt }))
        cache = items
    }
}
