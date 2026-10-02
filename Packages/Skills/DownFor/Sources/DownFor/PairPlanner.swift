import Foundation
import StarlingCore
import StarlingNegotiation

/// What the friend told the starter, privately, after PSI found shared time.
struct CandidateAnswers: Hashable, Sendable {
    /// Shared free half-hours (the PSI intersection).
    let overlap: [TimeSlot]
    /// The starter's activities this friend accepts.
    let activities: [Keyword]
}

/// Builds a quiet ask's pair plan from the friend's private answers
/// (private aggregation, brief 2.7). Plain code; the model never sees the
/// answers.
enum PairPlanner {
    /// The starter's first liked activity the friend accepts, at the first
    /// shared half-hour that starts no sooner than `earliest`. The time
    /// grows from that half-hour while the next one is shared too, up to
    /// `maxMinutes`.
    ///
    /// - Returns: The terms, with no roster (a pair's roster is the two
    ///   ends of the conversation), or nil when nothing fits.
    static func plan(liked: [Keyword], answers: CandidateAnswers, maxMinutes: Int64, earliest: Date) -> Terms? {
        guard let activity = liked.first(where: answers.activities.contains),
              let first = answers.overlap.filter({ $0.start >= earliest }).sorted().first
        else { return nil }
        var end = first.endMinute
        while end - first.startMinute + SlotTokenSet.slotMinutes <= maxMinutes,
              let next = try? TimeSlot(startMinute: end, endMinute: end + SlotTokenSet.slotMinutes),
              answers.overlap.contains(next) {
            end = next.endMinute
        }
        guard let time = try? TimeSlot(startMinute: first.startMinute, endMinute: end) else { return nil }
        return try? Terms([.time: .slots([time]), .activity: .keywords([activity])])
    }
}
