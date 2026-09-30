import CoreGraphics
import Foundation

/// A move from wherever the mark was toward the resting pose of `target`.
///
/// Plain values and pure functions of time, so every frame of the animation can
/// be tested without rendering. Times are seconds on one steady clock; the view
/// uses `Date.timeIntervalSinceReferenceDate`.
public struct MarkTransition: Equatable, Sendable {
    /// How long the shapes take to slide to a new pose.
    public static let moveDuration: TimeInterval = 0.8
    /// Under Reduce Motion, states crossfade for this long instead of moving.
    public static let crossfadeDuration: TimeInterval = 0.3
    /// The light in the gap rises over the last part of the move into the logo pose.
    public static let glowRise: TimeInterval = 0.2
    /// Then fades over this long, leaving the logo.
    public static let glowFade: TimeInterval = 1.6

    public var origin: MarkPose
    public var target: MarkState
    public var start: TimeInterval

    public init(origin: MarkPose, target: MarkState, start: TimeInterval) {
        self.origin = origin
        self.target = target
        self.start = start
    }

    /// A mark that has been in `state` since forever: no move and no glow.
    public init(resting state: MarkState) {
        self.init(origin: .resting(for: state), target: state, start: -.infinity)
    }

    /// Starts a new move from exactly where this one is at `time`, so nothing jumps.
    public func retargeted(to state: MarkState, at time: TimeInterval) -> MarkTransition {
        MarkTransition(origin: pose(at: time), target: state, start: time)
    }

    /// Eased progress of the move, from 0 to 1.
    public func progress(at time: TimeInterval) -> CGFloat {
        let linear = min(max((time - start) / Self.moveDuration, 0), 1)
        let eased = linear < 0.5 ? 4 * linear * linear * linear : 1 - pow(-2 * linear + 2, 3) / 2
        return CGFloat(eased)
    }

    public func pose(at time: TimeInterval) -> MarkPose {
        let fraction = progress(at: time)
        let target = MarkPose.resting(for: target)
        return fraction >= 1 ? target : origin.interpolated(to: target, fraction: fraction)
    }

    public func glow(at time: TimeInterval) -> CGFloat {
        guard target == .match else { return 0 }
        let elapsed = time - start
        let peak = Self.moveDuration
        let riseStart = peak - Self.glowRise
        if elapsed <= riseStart || elapsed >= peak + Self.glowFade { return 0 }
        if elapsed < peak { return CGFloat((elapsed - riseStart) / Self.glowRise) }
        let remaining = 1 - (elapsed - peak) / Self.glowFade
        return CGFloat(remaining * remaining)
    }

    /// What to draw at `time`. Under Reduce Motion the shapes hold the target's
    /// resting pose (the view crossfades between states) and only the light changes.
    public func frame(at time: TimeInterval, reduceMotion: Bool) -> MarkFrame {
        if reduceMotion {
            return MarkFrame(pose: MarkPose.resting(for: target).withoutMotion, glow: glow(at: time))
        }
        return MarkFrame(pose: pose(at: time), time: time, glow: glow(at: time))
    }

    /// When the drawing stops changing, or nil while the target keeps moving
    /// (searching and negotiating drift for as long as they last).
    public func settleTime(reduceMotion: Bool) -> TimeInterval? {
        if target == .match { return start + Self.moveDuration + Self.glowFade }
        if reduceMotion { return start }
        return MarkPose.resting(for: target).isMoving ? nil : start + Self.moveDuration
    }
}
