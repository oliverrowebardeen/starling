import Foundation
import StarlingCore

/// The group answer: one venue and the friends it fits. Computed on the
/// organizer's phone from each friend's acceptable list, which is all a
/// friend ever sends; nobody's budget or diet is in it (ADR 0230).
public struct GroupChoice: Hashable, Sendable {
    public let place: PlaceChoice
    /// Friends the place fits, sorted. The organizer is always in the plan
    /// and is not listed here.
    public let friends: [PeerID]

    public init(place: PlaceChoice, friends: [PeerID]) {
        self.place = place
        self.friends = friends
    }

    /// Picks the venue that fits the organizer and the most friends; then
    /// the lowest total rank across everyone it fits; then the organizer's
    /// order. Friends it does not fit are left out of the plan. Nil when no
    /// venue fits any friend.
    ///
    /// - Parameters:
    ///   - organizer: The organizer's acceptable venues, best first. Only
    ///     these count: they are the candidates that were asked about.
    ///   - answers: Each friend's acceptable venues, best first.
    public static func choose(organizer: [PlaceChoice], answers: [PeerID: [PlaceChoice]]) -> GroupChoice? {
        var best: (fans: [PeerID], rank: Int, index: Int)?
        var bestPlace: PlaceChoice?
        for (index, place) in organizer.enumerated() {
            var fans: [PeerID] = []
            var rank = index
            for (friend, list) in answers {
                guard let position = list.firstIndex(of: place) else { continue }
                fans.append(friend)
                rank += position
            }
            guard !fans.isEmpty else { continue }
            let better: Bool = if let best {
                (fans.count, -rank, -index) > (best.fans.count, -best.rank, -best.index)
            } else {
                true
            }
            if better {
                best = (fans, rank, index)
                bestPlace = place
            }
        }
        guard let best, let bestPlace else { return nil }
        return GroupChoice(place: bestPlace, friends: best.fans.sorted())
    }
}
