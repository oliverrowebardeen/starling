import Foundation
import StarlingCore

/// How one venue sits with one owner's private limits. Computed on the
/// owner's phone from facts this phone looked up; only the resulting list
/// of acceptable venues ever leaves it (ADR 0230).
public struct PlaceFit: Hashable, Sendable {
    public enum Conflict: Hashable, Sendable {
        /// Even the low end of the venue's price tier is over a hard budget.
        case overBudget
        /// Known not to serve a diet the owner needs.
        case dietNotServed(Keyword)
        /// The venue is a kind, or serves something, the owner avoids.
        case avoided(Keyword)
        /// This phone's lookup names the venue differently from the name a
        /// friend sent for the same Maps identifier.
        case nameMismatch
    }

    public let conflicts: [Conflict]
    /// Higher is better. Only known facts score; unknown facts score zero.
    public let score: Int
    /// Limits the facts could not check, such as a budget at a venue with no
    /// known price. Code never treats unknown as a conflict (ADR 0230).
    public let unchecked: Set<IssueKey>

    public var fits: Bool { conflicts.isEmpty }
}

/// The owner's hard limits are walk-away points, checked here in code, never
/// by a model (ARCHITECTURE rule 6).
public enum PlaceJudge {
    /// Diets one served diet also covers: a vegan place serves vegetarians.
    static let alsoCovers: [Keyword: Set<Keyword>] = [
        try! Keyword("vegan"): [try! Keyword("vegetarian"), try! Keyword("dairy free")],
    ]

    public static func fit(_ choice: PlaceChoice, facts: PlaceFacts, limits: ConstraintSet) -> PlaceFit {
        var conflicts: [PlaceFit.Conflict] = []
        var score = 0
        var unchecked: Set<IssueKey> = []

        if let known = facts.name, !sameName(known, choice.name) { conflicts.append(.nameMismatch) }

        for constraint in limits[.budget] {
            guard case .atMost(let limit) = constraint.rule else { continue }
            guard let tier = facts.priceTier, limit.currency == "USD" else {
                unchecked.insert(.budget)
                continue
            }
            let within = tier.typicalMinimumUSCents <= limit.minorUnits
            switch (within, constraint.strength) {
            case (true, _): score += 1
            case (false, .hard): conflicts.append(.overBudget)
            case (false, .soft): score -= 1
            }
        }

        let served = facts.diets.map { diets in diets.union(diets.flatMap { alsoCovers[$0] ?? [] }).union(facts.kinds) }
        for constraint in limits[.diet] {
            guard case .prefers(let needs, let avoided) = constraint.rule else { continue }
            for need in needs {
                if served?.contains(need) == true || facts.kinds.contains(need) {
                    score += 1
                } else if served == nil {
                    unchecked.insert(.diet)
                } else if constraint.strength == .hard {
                    conflicts.append(.dietNotServed(need))
                }
            }
            for item in avoided where facts.kinds.contains(item) {
                conflicts.append(.avoided(item))
            }
        }

        for constraint in limits[.place] {
            guard case .prefers(let liked, let avoided) = constraint.rule else { continue }
            score += 2 * liked.filter(facts.kinds.contains).count
            for item in avoided where facts.kinds.contains(item) {
                conflicts.append(.avoided(item))
            }
        }

        return PlaceFit(conflicts: conflicts, score: score, unchecked: unchecked)
    }

    /// The candidates that fit, best first; ties keep the given order.
    public static func acceptable(_ candidates: [PlaceCandidate], limits: ConstraintSet) -> [PlaceChoice] {
        candidates.enumerated()
            .map { (index: $0.offset, choice: $0.element.choice, fit: fit($0.element.choice, facts: $0.element.facts, limits: limits)) }
            .filter(\.fit.fits)
            .sorted { ($0.fit.score, -$0.index) > ($1.fit.score, -$1.index) }
            .map(\.choice)
    }

    private static func sameName(_ a: PlaceName, _ b: PlaceName) -> Bool {
        a.rawValue.compare(b.rawValue, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
    }
}
