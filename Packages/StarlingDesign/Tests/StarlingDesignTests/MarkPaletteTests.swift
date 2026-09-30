@testable import StarlingDesign
import Testing

@Suite struct MarkPaletteTests {
    @Test func tokensMatchTheBrief() {
        #expect(MarkPalette.light.shapeA == MarkColor(hex: 0x1F4FE0))
        #expect(MarkPalette.light.shapeB == MarkColor(hex: 0x5F80EE))
        #expect(MarkPalette.light.background == MarkColor(hex: 0xFAF9F6))
        #expect(MarkPalette.dark.shapeA == MarkColor(hex: 0x5B85FF))
        #expect(MarkPalette.dark.shapeB == MarkColor(hex: 0x3F63D6))
        #expect(MarkPalette.dark.background == MarkColor(hex: 0x141418))
    }

    /// WCAG 2.x contrast. The numbers are recorded in docs/brand/README.md.
    @Test func bothShapesHaveAtLeastThreeToOneAgainstTheirBackground() {
        for palette in [MarkPalette.light, .dark] {
            #expect(palette.shapeA.contrastRatio(against: palette.background) >= 3)
            #expect(palette.shapeB.contrastRatio(against: palette.background) >= 3)
        }
        #expect(abs(MarkPalette.light.shapeA.contrastRatio(against: MarkPalette.light.background) - 6.13) < 0.01)
        #expect(abs(MarkPalette.light.shapeB.contrastRatio(against: MarkPalette.light.background) - 3.43) < 0.01)
        #expect(abs(MarkPalette.dark.shapeA.contrastRatio(against: MarkPalette.dark.background) - 5.46) < 0.01)
        #expect(abs(MarkPalette.dark.shapeB.contrastRatio(against: MarkPalette.dark.background) - 3.47) < 0.01)
    }
}
