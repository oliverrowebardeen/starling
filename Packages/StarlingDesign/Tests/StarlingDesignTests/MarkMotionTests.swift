import CoreGraphics
import Foundation
@testable import StarlingDesign
import Testing

@Suite struct MarkMotionTests {
    @Test func aTransitionStartsWhereTheMarkWasAndEndsAtTheTargetPose() {
        let idle = MarkTransition(resting: .idle)
        let toNegotiating = idle.retargeted(to: .negotiating, at: 10)
        #expect(toNegotiating.pose(at: 10) == .resting(for: .idle))
        #expect(toNegotiating.pose(at: 10 + MarkTransition.moveDuration) == .resting(for: .negotiating))
        #expect(toNegotiating.pose(at: 10 + 5) == .resting(for: .negotiating))
    }

    @Test func retargetingMidwayDoesNotJump() {
        let first = MarkTransition(resting: .idle).retargeted(to: .negotiating, at: 0)
        let midway = first.pose(at: 0.3)
        let second = first.retargeted(to: .match, at: 0.3)
        #expect(second.pose(at: 0.3) == midway)
        #expect(second.frame(at: 0.3, reduceMotion: false) == first.frame(at: 0.3, reduceMotion: false))
    }

    @Test func separationChangesMonotonicallyWhileShapesSlideIn() {
        let transition = MarkTransition(resting: .idle).retargeted(to: .match, at: 0)
        var last = CGFloat.infinity
        for step in 0...40 {
            let dx = transition.pose(at: Double(step) * 0.025).separation.dx
            #expect(dx <= last)
            last = dx
        }
    }

    @Test func searchingPulsesYourShapeAndDriftsBoth() {
        let searching = MarkTransition(resting: .searching)
        let scales = stride(from: 0.0, to: 2, by: 0.1).map { searching.frame(at: $0, reduceMotion: false).scaleA }
        #expect(scales.contains { $0 > 1.02 })
        #expect(scales.contains { $0 < 0.98 })
        let separations = stride(from: 0.0, to: 5, by: 0.25).map { time -> CGFloat in
            let frame = searching.frame(at: time, reduceMotion: false)
            return frame.centerB.x - frame.centerA.x
        }
        #expect((separations.max() ?? 0) - (separations.min() ?? 0) > 4)
        #expect(searching.settleTime(reduceMotion: false) == nil)
    }

    @Test func matchFillsTheGapWithLightThenFades() {
        let match = MarkTransition(resting: .negotiating).retargeted(to: .match, at: 0)
        #expect(match.glow(at: 0) == 0)
        #expect(match.glow(at: MarkTransition.moveDuration) == 1)
        let fading = match.glow(at: MarkTransition.moveDuration + MarkTransition.glowFade / 2)
        #expect(fading > 0 && fading < 1)
        let end = MarkTransition.moveDuration + MarkTransition.glowFade
        #expect(match.glow(at: end) == 0)
        #expect(match.settleTime(reduceMotion: false) == end)
    }

    @Test func noOtherStateGlows() {
        for state in MarkState.allCases where state != .match {
            let transition = MarkTransition(resting: .negotiating).retargeted(to: state, at: 0)
            for step in 0...40 {
                #expect(transition.glow(at: Double(step) * 0.1) == 0)
            }
        }
    }

    @Test func noMatchDriftsApartFadesAndStops() {
        let transition = MarkTransition(resting: .negotiating).retargeted(to: .noMatch, at: 0)
        let end = transition.frame(at: MarkTransition.moveDuration, reduceMotion: false)
        #expect(!end.shapesOverlap)
        #expect(end.opacityB < 0.5)
        #expect(end.centerB.x - end.centerA.x > MarkPose.resting(for: .idle).separation.dx)
        #expect(transition.settleTime(reduceMotion: false) == MarkTransition.moveDuration)
    }

    @Test func reduceMotionShowsTheRestingPoseWithNoDriftOrPulse() {
        for state in MarkState.allCases {
            let transition = MarkTransition(resting: .idle).retargeted(to: state, at: 0)
            let resting = MarkFrame(pose: MarkPose.resting(for: state).withoutMotion)
            for time in [0.0, 0.2, 1.3, 7.1] {
                var frame = transition.frame(at: time, reduceMotion: true)
                frame.glow = 0
                #expect(frame == resting, "\(state) at \(time)")
            }
        }
        // Only the light in the gap changes over time, and only for a match.
        #expect(MarkTransition(resting: .idle).retargeted(to: .searching, at: 0).settleTime(reduceMotion: true) == 0)
        #expect(MarkTransition(resting: .idle).retargeted(to: .match, at: 0).settleTime(reduceMotion: true)
            == MarkTransition.moveDuration + MarkTransition.glowFade)
    }

    @Test func aMarkThatStartsInAStateIsAlreadySettled() {
        let match = MarkTransition(resting: .match)
        #expect(match.frame(at: 1_000_000, reduceMotion: false) == .logo)
        #expect(match.glow(at: 1_000_000) == 0)
    }
}
