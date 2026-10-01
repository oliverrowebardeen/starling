import PickAPlace
import StarlingCore
import Testing

@Suite("Private fit")
struct PlaceFitTests {
    @Test func noLimitsMeansEveryPlaceFitsInOrder() {
        let places = [candidate("Tea Lab"), candidate("Boba Guys")]
        #expect(PlaceJudge.acceptable(places, limits: .empty) == places.map(\.choice))
    }

    @Test(arguments: [
        (PriceTier.one, true), (.two, true), (.three, false), (.four, false),
    ])
    func hardBudgetRejectsTiersWhoseLowEndIsOverIt(tier: PriceTier, fits: Bool) {
        let fit = PlaceJudge.fit(place("A"), facts: PlaceFacts(priceTier: tier), limits: limits(budget: 20))
        #expect(fit.fits == fits)
        if !fits { #expect(fit.conflicts == [.overBudget]) }
    }

    @Test func unknownPriceIsUncheckedNotAConflict() {
        let fit = PlaceJudge.fit(place("A"), facts: .unknown, limits: limits(budget: 10))
        #expect(fit.fits)
        #expect(fit.unchecked == [.budget])
        #expect(fit.score == 0)
    }

    @Test func softBudgetOnlyLowersTheScore() {
        let over = PlaceJudge.fit(place("A"), facts: PlaceFacts(priceTier: .three), limits: limits(softBudget: 20))
        #expect(over.fits)
        #expect(over.score == -1)
    }

    @Test func aBudgetInAnotherCurrencyIsUnchecked() throws {
        let euros = try ConstraintSet([.budget: [Constraint(.atMost(MoneyAmount(minorUnits: 100, currency: "EUR")))]])
        let fit = PlaceJudge.fit(place("A"), facts: PlaceFacts(priceTier: .four), limits: euros)
        #expect(fit.fits)
        #expect(fit.unchecked == [.budget])
    }

    @Test func hardDietNeedRejectsAPlaceKnownNotToServeIt() {
        let steak = PlaceFacts(diets: [], kinds: [kw("steakhouse")])
        #expect(PlaceJudge.fit(place("A"), facts: steak, limits: limits(needs: ["vegetarian"])).conflicts == [.dietNotServed(kw("vegetarian"))])
    }

    @Test func aVeganPlaceServesVegetarians() {
        let vegan = PlaceFacts(diets: [kw("vegan")])
        let fit = PlaceJudge.fit(place("A"), facts: vegan, limits: limits(needs: ["vegetarian"]))
        #expect(fit.fits)
        #expect(fit.score == 1)
    }

    @Test func unknownDietsAreUnchecked() {
        let fit = PlaceJudge.fit(place("A"), facts: .unknown, limits: limits(needs: ["halal"]))
        #expect(fit.fits)
        #expect(fit.unchecked == [.diet])
    }

    @Test func softDietNeedNeverRejects() {
        let fit = PlaceJudge.fit(place("A"), facts: PlaceFacts(diets: []), limits: limits(softNeeds: ["vegan"]))
        #expect(fit.fits)
    }

    @Test func avoidedKindsAlwaysReject() {
        let sushi = PlaceFacts(kinds: [kw("sushi"), kw("restaurant")])
        #expect(PlaceJudge.fit(place("A"), facts: sushi, limits: limits(avoid: ["sushi"])).conflicts == [.avoided(kw("sushi"))])
        #expect(PlaceJudge.fit(place("A"), facts: sushi, limits: limits(avoidKinds: ["sushi"])).conflicts == [.avoided(kw("sushi"))])
    }

    @Test func aDifferentNameForTheSameIdentifierIsAConflict() throws {
        let facts = PlaceFacts(name: try PlaceName("Hog & Rocks"), kinds: [kw("restaurant")])
        #expect(PlaceJudge.fit(place("Green Garden Vegan"), facts: facts, limits: .empty).conflicts == [.nameMismatch])
        #expect(PlaceJudge.fit(place("hog & rocks"), facts: facts, limits: .empty).fits)
    }

    @Test func ranksKnownFitsAndLikedKindsFirst() {
        let places = [
            candidate("Unknown Cafe"),
            candidate("Cheap Boba", tier: .one, kinds: ["boba"]),
            candidate("Pricey", tier: .four),
            candidate("Fine Boba", tier: .two, kinds: ["boba"]),
        ]
        let ranked = PlaceJudge.acceptable(places, limits: limits(budget: 20, likes: ["boba"]))
        #expect(ranked.map(\.name.rawValue) == ["Cheap Boba", "Fine Boba", "Unknown Cafe"])
    }
}
