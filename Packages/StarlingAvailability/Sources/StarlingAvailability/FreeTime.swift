import Foundation
import StarlingCore

/// Plain arithmetic over time: free stretches from busy blocks, and which
/// candidate slots fit inside them. No model, no I/O.
public enum FreeTime {
    /// The free stretches of `window` around the blocks that take time, each
    /// at least `minimumMinutes` long, in order.
    ///
    /// Busy time is widened to whole minutes (start rounded down, end up), so
    /// a block never leaves a sliver of "free" time that is really taken.
    public static func free(in window: TimeSlot, around blocks: [BusyBlock], minimumMinutes: Int = 1) -> [TimeSlot] {
        let busy = blocks.filter(\.blocksTime).compactMap { block -> (Int64, Int64)? in
            let start = max(window.startMinute, Int64((block.start.timeIntervalSince1970 / 60).rounded(.down)))
            let end = min(window.endMinute, Int64((block.end.timeIntervalSince1970 / 60).rounded(.up)))
            return end > start ? (start, end) : nil
        }.sorted { $0.0 < $1.0 }

        var free: [TimeSlot] = []
        var cursor = window.startMinute
        for (start, end) in busy {
            if start > cursor, let slot = try? TimeSlot(startMinute: cursor, endMinute: start) { free.append(slot) }
            cursor = max(cursor, end)
        }
        if window.endMinute > cursor, let slot = try? TimeSlot(startMinute: cursor, endMinute: window.endMinute) { free.append(slot) }
        return free.filter { $0.durationMinutes >= Int64(max(1, minimumMinutes)) }
    }

    /// The candidates that lie entirely inside one free stretch, in the
    /// candidates' order, without duplicates.
    public static func acceptable(_ candidates: [TimeSlot], within free: [TimeSlot]) -> [TimeSlot] {
        var seen: Set<TimeSlot> = []
        return candidates.filter { candidate in
            free.contains { $0.startMinute <= candidate.startMinute && candidate.endMinute <= $0.endMinute } && seen.insert(candidate).inserted
        }
    }
}

/// Candidate times for a range: slots of one length, starting on a grid
/// inside a daily window in the owner's time zone ("next week, 9 to 9").
public struct CandidateGrid: Hashable, Sendable {
    /// Bounds the work of building a grid; a 14-day range of 15-minute slots
    /// is 1,344.
    public static let maxGenerated = 2_000

    public let durationMinutes: Int
    /// The daily window, in local minutes after midnight (`0...1440`).
    public let dailyFrom: Int
    public let dailyTo: Int

    public init(durationMinutes: Int, dailyFrom: Int = 0, dailyTo: Int = 1440) throws {
        guard (5...720).contains(durationMinutes) else { throw ValidationError("CandidateGrid.duration", "must be 5-720 minutes") }
        guard (0...1440).contains(dailyFrom), (0...1440).contains(dailyTo), dailyTo - dailyFrom >= durationMinutes else {
            throw ValidationError("CandidateGrid.daily", "must satisfy 0 <= from, from + duration <= to <= 1440")
        }
        self.durationMinutes = durationMinutes
        self.dailyFrom = dailyFrom
        self.dailyTo = dailyTo
    }

    /// Every slot of `durationMinutes` that starts on the grid (the daily
    /// window's start, then every `durationMinutes`), lies inside one of
    /// `ranges` and the daily window, and starts at or after `notBefore`.
    /// Sorted, without duplicates.
    public func slots(in ranges: [TimeSlot], notBefore: Date, timeZone: TimeZone) -> [TimeSlot] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let earliest = Int64((notBefore.timeIntervalSince1970 / 60).rounded(.up))
        var found: Set<TimeSlot> = []

        for range in ranges {
            var day = calendar.startOfDay(for: range.start)
            while day < range.end, found.count < Self.maxGenerated {
                if let open = calendar.date(byAdding: .minute, value: dailyFrom, to: day),
                   let close = calendar.date(byAdding: .minute, value: dailyTo, to: day) {
                    let closeMinute = Int64((close.timeIntervalSince1970 / 60).rounded(.down))
                    var start = Int64((open.timeIntervalSince1970 / 60).rounded(.up))
                    let duration = Int64(durationMinutes)
                    while start + duration <= closeMinute, found.count < Self.maxGenerated {
                        if start >= max(range.startMinute, earliest), start + duration <= range.endMinute,
                           let slot = try? TimeSlot(startMinute: start, endMinute: start + duration) {
                            found.insert(slot)
                        }
                        start += duration
                    }
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return found.sorted()
    }

    /// At most `limit` of `slots`, spread evenly from first to last so a long
    /// range still offers every part of it, not only its first day.
    public static func thinned(_ slots: [TimeSlot], to limit: Int) -> [TimeSlot] {
        guard limit > 0 else { return [] }
        guard slots.count > limit else { return slots }
        if limit == 1 { return [slots[0]] }
        let last = slots.count - 1
        return (0..<limit).map { slots[($0 * last) / (limit - 1)] }
    }
}
