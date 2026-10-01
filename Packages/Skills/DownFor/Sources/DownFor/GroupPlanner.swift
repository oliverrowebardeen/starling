import Foundation
import StarlingCore
import StarlingNegotiation

/// What one friend told the starter, privately, after PSI found shared time.
struct CandidateAnswers: Hashable, Sendable {
    /// Shared free half-hours (the PSI intersection).
    let overlap: [TimeSlot]
    /// The starter's activities this friend accepts.
    let activities: [Keyword]
}

/// Builds the group plan from every friend's private answers (private
/// aggregation, brief 2.7). Plain code; the model never sees the answers.
enum GroupPlanner {
    /// The plan that includes the most friends: for each of the starter's
    /// liked activities and each shared half-hour, the largest set of
    /// friends who share both and who may all be in a plan together. Ties go
    /// to the starter's earlier preference, then the earlier time. The time
    /// grows from that half-hour while every chosen friend shares the next
    /// one, up to `maxMinutes`.
    ///
    /// - Parameter together: Whether two friends may share a plan: each one's
    ///   own request includes the other (review of PR #56, finding 1). A
    ///   pair with the starter needs nothing more.
    /// - Returns: The terms and the friends in them, or nil when no friend
    ///   shares both a time and an activity. A group of three or more
    ///   carries its roster, `hub` first.
    static func plan(
        hub: PeerID,
        liked: [Keyword],
        candidates: [PeerID: CandidateAnswers],
        maxMinutes: Int64,
        now: Date,
        together: (PeerID, PeerID) -> Bool = { _, _ in true }
    ) -> (terms: Terms, members: [PeerID])? {
        let starts = Set(candidates.values.flatMap(\.overlap)).filter { DownForProfile.hasNotStarted($0, now: now) }.sorted()
        var best: (members: [PeerID], likedIndex: Int, slot: TimeSlot, activity: Keyword)?
        for (index, activity) in liked.enumerated() {
            for slot in starts {
                let fits = candidates.keys.filter { peer in
                    let answers = candidates[peer]!
                    return answers.overlap.contains(slot) && answers.activities.contains(activity)
                }.sorted()
                let members = largestGroup(of: fits, together: together)
                guard !members.isEmpty else { continue }
                if let current = best, members.count <= current.members.count { continue }
                best = (members, index, slot, activity)
            }
        }
        guard let best else { return nil }

        var end = best.slot.endMinute
        while end - best.slot.startMinute + SlotTokenSet.slotMinutes <= maxMinutes,
              let next = try? TimeSlot(startMinute: end, endMinute: end + SlotTokenSet.slotMinutes),
              best.members.allSatisfy({ candidates[$0]!.overlap.contains(next) }) {
            end = next.endMinute
        }
        guard let time = try? TimeSlot(startMinute: best.slot.startMinute, endMinute: end) else { return nil }

        var values: [IssueKey: IssueValue] = [.time: .slots([time]), .activity: .keywords([best.activity])]
        if best.members.count >= 2 { values[.people] = .peers([hub] + best.members) }
        guard let terms = try? Terms(values) else { return nil }
        return (terms, best.members)
    }

    /// The largest set of `peers` in which every two may be together; among
    /// sets of that size, the first in `peers` order. At most 15 friends, so
    /// a plain search is fast enough.
    static func largestGroup(of peers: [PeerID], together: (PeerID, PeerID) -> Bool) -> [PeerID] {
        var best: [PeerID] = []
        func grow(_ chosen: [PeerID], from index: Int) {
            if chosen.count > best.count { best = chosen }
            guard chosen.count + (peers.count - index) > best.count else { return }
            for next in index..<peers.count where chosen.allSatisfy({ together($0, peers[next]) && together(peers[next], $0) }) {
                grow(chosen + [peers[next]], from: next + 1)
            }
        }
        grow([], from: 0)
        return best
    }
}
