@testable import StarlingDesign
import SwiftUI
import Testing

@Suite struct PairSymbolTests {
    /// DESIGN.md section 4: both shapes at least 3:1 against the background,
    /// in light and in dark.
    @Test func everyPairKeepsThreeToOneInBothAppearances() {
        for pair in PairPalette.pairs + [PairPalette.own] {
            for scheme in [ColorScheme.light, .dark] {
                let palette = pair.palette(for: scheme)
                #expect(palette.shapeA.contrastRatio(against: palette.background) >= 3, "\(pair.name) \(scheme) A")
                #expect(palette.shapeB.contrastRatio(against: palette.background) >= 3, "\(pair.name) \(scheme) B")
            }
        }
    }

    @Test func theTwoShapesOfAPairStayDistinguishable() {
        for pair in PairPalette.pairs {
            #expect(pair.light.shapeA != pair.light.shapeB, "\(pair.name)")
            #expect(pair.dark.shapeA != pair.dark.shapeB, "\(pair.name)")
        }
    }

    @Test func friendsNeverGetTheOwnersBrandPair() {
        #expect(PairPalette.own == PairColors(name: "brand", light: (0x1F4FE0, 0x5F80EE), dark: (0x5B85FF, 0x3F63D6)))
        #expect(!PairPalette.pairs.contains { $0.light == PairPalette.own.light || $0.dark == PairPalette.own.dark })
        #expect(Set(PairPalette.pairs.map(\.name)).count == PairPalette.pairs.count)
    }

    @Test func theSameSeedAlwaysGetsTheSamePair() {
        let seed: [UInt8] = (0..<32).map { UInt8($0 * 7 % 256) }
        #expect(PairPalette.colors(for: seed) == PairPalette.colors(for: seed))
        #expect(PairPalette.colors(for: [UInt8]()) == PairPalette.pairs[0])
    }

    /// Uniform seeds (SHA-256 output in the app) spread over every pair.
    @Test func uniformSeedsReachEveryPair() {
        var generator = SystemRandomNumberGenerator()
        var seen = Set<String>()
        for _ in 0..<2_000 {
            let seed = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            seen.insert(PairPalette.colors(for: seed).name)
        }
        #expect(seen.count == PairPalette.pairs.count)
    }

    /// Only the first eight bytes choose the pair, so trailing bytes a
    /// friend cannot see do not change it.
    @Test func onlyTheFirstEightBytesChoose() {
        let head: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        #expect(PairPalette.colors(for: head + [9, 9, 9]) == PairPalette.colors(for: head + [0, 0]))
    }
}
