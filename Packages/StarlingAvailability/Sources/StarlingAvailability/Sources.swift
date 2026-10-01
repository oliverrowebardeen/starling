import Foundation
import StarlingCore

/// Free time from the owner's calendar, busy and free only.
///
/// Answers `.unknown`, so the next source decides, when the owner chose
/// "Just ask me" or the calendar cannot be read. It never asks for the
/// permission itself; see `CalendarAccess`.
public struct EventKitAvailabilitySource: AvailabilitySource {
    public let kind = AvailabilitySourceKind.calendar
    private let store: any CalendarStore
    private let use: @Sendable () async -> CalendarUse

    public init(store: any CalendarStore, use: @escaping @Sendable () async -> CalendarUse) {
        self.store = store
        self.use = use
    }

    public func availability(for query: AvailabilityQuery) async throws -> AvailabilityAnswer {
        guard await use() == .useMyCalendar, store.accessStatus().canRead else { return .unknown }
        let blocks = try await store.blocks(from: query.window.start, to: query.window.end)
        return .known(free: FreeTime.free(in: query.window, around: blocks, minimumMinutes: query.granularityMinutes))
    }
}

/// Free time the owner has stated, such as "free tonight 7 to 11" from an
/// active Down for…, or an earlier answer to the agent's question.
///
/// Inside a stated window the owner is free; outside it the source does not
/// guess that they are, so a query that touches no stated window is
/// `.unknown`, and one that does gets only the stated part.
public struct StatedIntentAvailabilitySource: AvailabilitySource {
    public let kind = AvailabilitySourceKind.statedIntent
    private let windows: @Sendable () async -> [TimeSlot]

    public init(windows: @escaping @Sendable () async -> [TimeSlot]) {
        self.windows = windows
    }

    public func availability(for query: AvailabilityQuery) async throws -> AvailabilityAnswer {
        let free = await windows()
            .compactMap { $0.overlap(with: query.window) }
            .filter { $0.durationMinutes >= Int64(query.granularityMinutes) }
            .sorted()
        return free.isEmpty ? .unknown : .known(free: free)
    }
}

/// The last resort: only the owner knows. Always answers `.needsOwner` with
/// up to `maxSuggestions` one-tap slots across the window.
public struct AskOwnerAvailabilitySource: AvailabilitySource {
    public let kind = AvailabilitySourceKind.askOwner
    public let maxSuggestions: Int

    public init(maxSuggestions: Int = 12) {
        self.maxSuggestions = max(1, maxSuggestions)
    }

    public func availability(for query: AvailabilityQuery) async throws -> AvailabilityAnswer {
        let grid = try CandidateGrid(durationMinutes: min(query.granularityMinutes, 720))
        let slots = grid.slots(in: [query.window], notBefore: query.window.start, timeZone: TimeZone(identifier: "UTC")!)
        return .needsOwner(OwnerQuestion(window: query.window, suggestions: CandidateGrid.thinned(slots, to: maxSuggestions)))
    }
}

/// The owner's availability: sources tried in order until one knows.
///
/// The standard order is the calendar, then stated intent, then the owner.
/// A source that fails (a calendar read error) is skipped like one that does
/// not know, so a broken calendar falls back to asking, never to a guess.
public struct OwnerAvailability: Sendable {
    public let sources: [any AvailabilitySource]

    public init(_ sources: [any AvailabilitySource]) {
        self.sources = sources
    }

    /// Calendar (if the owner uses it and it can be read), then stated
    /// intent, then the owner.
    public static func standard(
        calendar: any CalendarStore,
        use: @escaping @Sendable () async -> CalendarUse,
        stated: @escaping @Sendable () async -> [TimeSlot] = { [] }
    ) -> OwnerAvailability {
        OwnerAvailability([
            EventKitAvailabilitySource(store: calendar, use: use),
            StatedIntentAvailabilitySource(windows: stated),
            AskOwnerAvailabilitySource(),
        ])
    }

    /// The first answer that is not `.unknown`, with the source that gave
    /// it, or `.unknown` and nil when no source knows.
    public func answer(for query: AvailabilityQuery) async -> (answer: AvailabilityAnswer, source: AvailabilitySourceKind?) {
        for source in sources {
            guard let answer = try? await source.availability(for: query) else { continue }
            if case .unknown = answer { continue }
            return (answer, source.kind)
        }
        return (.unknown, nil)
    }

    /// Which of `candidates` the owner is free for, or that only the owner
    /// can say. Candidates are grouped into windows of at most 14 days (the
    /// longest `TimeSlot`); if any window needs the owner, the whole set
    /// does, so the owner gets one question rather than several.
    public func resolve(_ candidates: [TimeSlot]) async -> CandidateResolution {
        let sorted = Array(Set(candidates)).sorted()
        guard let first = sorted.first else { return .known(acceptable: [], source: nil) }
        let granularity = Int(min(1440, max(5, sorted.map(\.durationMinutes).min() ?? 30)))

        var chunks: [[TimeSlot]] = [[first]]
        for slot in sorted.dropFirst() {
            if let start = chunks[chunks.count - 1].first, slot.endMinute - start.startMinute <= ProtocolLimits.maxSlotMinutes {
                chunks[chunks.count - 1].append(slot)
            } else {
                chunks.append([slot])
            }
        }

        var acceptable: [TimeSlot] = []
        var known: AvailabilitySourceKind?
        for chunk in chunks {
            guard let start = chunk.first?.startMinute, let end = chunk.map(\.endMinute).max(),
                  let window = try? TimeSlot(startMinute: start, endMinute: end),
                  let query = try? AvailabilityQuery(window: window, granularityMinutes: granularity)
            else { return .askOwner }
            switch await answer(for: query) {
            case (.known(let free), let source):
                acceptable += FreeTime.acceptable(chunk, within: free)
                known = known ?? source
            case (.needsOwner, _), (.unknown, _):
                return .askOwner
            }
        }
        return .known(acceptable: acceptable, source: known)
    }
}

/// What `OwnerAvailability.resolve(_:)` found.
public enum CandidateResolution: Hashable, Sendable {
    /// The candidates the owner is free for (possibly none), and the source
    /// that knew.
    case known(acceptable: [TimeSlot], source: AvailabilitySourceKind?)
    /// No source knows: ask the owner which candidates work.
    case askOwner
}
