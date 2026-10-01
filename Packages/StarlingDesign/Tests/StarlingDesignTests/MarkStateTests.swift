@testable import StarlingDesign
import Testing

@Suite struct MarkStateTests {
    /// DESIGN.md section 3 and ADR 0017: plan words replace Phase 1's
    /// "Looking for a match" and "Matched".
    @Test func voiceOverLabelsUsePlanWords() {
        #expect(MarkState.idle.accessibilityLabel == "Starling")
        #expect(MarkState.searching.accessibilityLabel == "Checking with friends")
        #expect(MarkState.negotiating.accessibilityLabel == "Agents are talking")
        #expect(MarkState.match.accessibilityLabel == "It's a plan")
        #expect(MarkState.noMatch.accessibilityLabel == "Starling")
    }
}
