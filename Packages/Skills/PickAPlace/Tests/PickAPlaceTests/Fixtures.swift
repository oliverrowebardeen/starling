import Foundation
import PickAPlace
import StarlingCore

func kw(_ text: String) -> Keyword { try! Keyword(text) }

func place(_ name: String, id: String? = nil) -> PlaceChoice {
    try! PlaceChoice(name: PlaceName(name), mapItemID: id)
}

func candidate(_ name: String, id: String? = nil, tier: PriceTier? = nil, diets: [String]? = nil, kinds: [String] = []) -> PlaceCandidate {
    PlaceCandidate(
        choice: place(name, id: id),
        facts: PlaceFacts(name: try! PlaceName(name), priceTier: tier, diets: diets.map { Set($0.map(kw)) }, kinds: Set(kinds.map(kw)))
    )
}

func usd(_ dollars: Int64) -> MoneyAmount { try! MoneyAmount(minorUnits: dollars * 100) }

/// An owner's private limits, the way the intent chips or standing rules
/// hold them.
func limits(
    budget: Int64? = nil,
    softBudget: Int64? = nil,
    needs: [String] = [],
    softNeeds: [String] = [],
    avoid: [String] = [],
    likes: [String] = [],
    avoidKinds: [String] = []
) -> ConstraintSet {
    var rules: [IssueKey: [Constraint]] = [:]
    if let budget { rules[.budget, default: []].append(try! Constraint(.atMost(usd(budget)))) }
    if let softBudget { rules[.budget, default: []].append(try! Constraint(.atMost(usd(softBudget)), strength: .soft)) }
    if !needs.isEmpty || !avoid.isEmpty {
        rules[.diet, default: []].append(try! Constraint(.prefers(liked: needs.map(kw), avoided: avoid.map(kw))))
    }
    if !softNeeds.isEmpty {
        rules[.diet, default: []].append(try! Constraint(.prefers(liked: softNeeds.map(kw), avoided: []), strength: .soft))
    }
    if !likes.isEmpty || !avoidKinds.isEmpty {
        rules[.place, default: []].append(try! Constraint(.prefers(liked: likes.map(kw), avoided: avoidKinds.map(kw)), strength: .soft))
    }
    return try! ConstraintSet(rules)
}
