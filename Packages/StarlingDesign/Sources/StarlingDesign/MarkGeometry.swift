import CoreGraphics
import Foundation
import SwiftUI

/// Geometry of the Overlap mark, in logo units.
///
/// The mark is two identical rounded rectangles in a frame rotated 20 degrees
/// clockwise. Points are given in that rotated frame with the canvas center at
/// the origin and y pointing down. The numbers match the app icon layers and the
/// flat logo: 40 by 56 units, corner radius 14, and in the logo pose the centers
/// sit at (-10, -8) and (10, 8).
public enum MarkGeometry {
    public static let shapeSize = CGSize(width: 40, height: 56)
    public static let cornerRadius: CGFloat = 14
    public static let rotation = Angle.degrees(20)
    /// Side of the square canvas, in units. The app icon canvas is 1024 px with a
    /// 123.29 px corner radius, so this makes the logo pose line up with the icon.
    public static let canvasUnits: CGFloat = 1024 / (123.29 / 14)

    /// Maps the rotated unit frame onto the largest square centered in `rect`.
    public static func transform(in rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width, rect.height) / canvasUnits
        return CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: rotation.radians)
            .scaledBy(x: scale, y: scale)
    }

    public static func point(_ unit: CGPoint, in rect: CGRect) -> CGPoint {
        unit.applying(transform(in: rect))
    }

    /// One shape of the mark, in view coordinates. Circular corners, like the icon.
    public static func shapePath(center: CGPoint, scale: CGFloat = 1, in rect: CGRect) -> Path {
        let size = CGSize(width: shapeSize.width * scale, height: shapeSize.height * scale)
        let bounds = CGRect(origin: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), size: size)
        return Path(roundedRect: bounds, cornerRadius: cornerRadius * scale, style: .circular)
            .applying(transform(in: rect))
    }

    /// Whether `point` is inside the shape centered at `shapeCenter`, both in units.
    public static func contains(_ point: CGPoint, shapeCenter: CGPoint, scale: CGFloat = 1) -> Bool {
        let halfWidth = shapeSize.width * scale / 2, halfHeight = shapeSize.height * scale / 2
        let radius = cornerRadius * scale
        let dx = abs(point.x - shapeCenter.x), dy = abs(point.y - shapeCenter.y)
        guard dx <= halfWidth, dy <= halfHeight else { return false }
        let cornerX = max(dx - (halfWidth - radius), 0), cornerY = max(dy - (halfHeight - radius), 0)
        return cornerX * cornerX + cornerY * cornerY <= radius * radius
    }

    /// Centers of the four corner arcs of a shape, in units.
    static func cornerCenters(center: CGPoint, scale: CGFloat) -> [CGPoint] {
        let dx = (shapeSize.width / 2 - cornerRadius) * scale
        let dy = (shapeSize.height / 2 - cornerRadius) * scale
        return [(-1, -1), (1, -1), (1, 1), (-1, 1)].map { CGPoint(x: center.x + $0 * dx, y: center.y + $1 * dy) }
    }
}

/// The target of a state: where the shapes rest and how they move there.
public struct MarkPose: Equatable, Sendable {
    /// From shape A's center to shape B's, in units, in the rotated frame.
    public var separation: CGVector
    /// How far the separation wanders, in units. Zero means still.
    public var drift: CGFloat
    /// How strongly shape A breathes, from 0 to 1.
    public var pulse: CGFloat
    /// Opacity of shape B.
    public var opacityB: CGFloat

    public init(separation: CGVector, drift: CGFloat = 0, pulse: CGFloat = 0, opacityB: CGFloat = 1) {
        self.separation = separation
        self.drift = drift
        self.pulse = pulse
        self.opacityB = opacityB
    }

    /// The app icon and the flat logo.
    public static let logo = MarkPose(separation: CGVector(dx: 20, dy: 16))

    /// Values follow the owner's motion reference (starling_logo_status_animation.html).
    public static func resting(for state: MarkState) -> MarkPose {
        switch state {
        case .idle: MarkPose(separation: CGVector(dx: 44, dy: 22))
        case .searching: MarkPose(separation: CGVector(dx: 44, dy: 22), drift: 5, pulse: 1)
        case .negotiating: MarkPose(separation: CGVector(dx: 29, dy: 19), drift: 1.2)
        case .match: .logo
        case .noMatch: MarkPose(separation: CGVector(dx: 52, dy: 30), opacityB: 0.25)
        }
    }

    /// The same pose, held still.
    public var withoutMotion: MarkPose {
        MarkPose(separation: separation, opacityB: opacityB)
    }

    var isMoving: Bool { drift > 0 || pulse > 0 }

    public func interpolated(to other: MarkPose, fraction: CGFloat) -> MarkPose {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * fraction }
        return MarkPose(
            separation: CGVector(dx: mix(separation.dx, other.separation.dx), dy: mix(separation.dy, other.separation.dy)),
            drift: mix(drift, other.drift),
            pulse: mix(pulse, other.pulse),
            opacityB: mix(opacityB, other.opacityB)
        )
    }
}

/// One drawable instant of the mark.
public struct MarkFrame: Equatable, Sendable {
    public var centerA: CGPoint
    public var centerB: CGPoint
    public var scaleA: CGFloat
    public var opacityB: CGFloat
    /// Light in the gap, from 0 to 1. Only a match lights it.
    public var glow: CGFloat

    /// Places the shapes for `pose` at `time` seconds on any steady clock.
    /// The drift and pulse are periodic in `time`, so the same clock must be used frame to frame.
    public init(pose: MarkPose, time: TimeInterval = 0, glow: CGFloat = 0) {
        let dx = pose.separation.dx + pose.drift * CGFloat(sin(time * 1.3))
        let dy = pose.separation.dy + pose.drift * CGFloat(cos(time * 0.9))
        centerA = CGPoint(x: -dx / 2, y: -dy / 2)
        centerB = CGPoint(x: dx / 2, y: dy / 2)
        scaleA = 1 + 0.04 * pose.pulse * CGFloat(sin(time * 4))
        opacityB = pose.opacityB
        self.glow = glow
    }

    public static let logo = MarkFrame(pose: .logo)

    /// Midway between the centers. When the shapes overlap, this is inside the gap.
    public var overlapCenter: CGPoint {
        CGPoint(x: (centerA.x + centerB.x) / 2, y: (centerA.y + centerB.y) / 2)
    }

    public var shapesOverlap: Bool {
        MarkGeometry.contains(overlapCenter, shapeCenter: centerA, scale: scaleA)
            && MarkGeometry.contains(overlapCenter, shapeCenter: centerB)
    }
}

/// Still poses for places that cannot animate, such as a future Dynamic Island.
public enum StaticMarkPose: CaseIterable, Sendable {
    case apart
    case close
    case logo

    public var frame: MarkFrame {
        switch self {
        case .apart: MarkFrame(pose: MarkPose.resting(for: .idle).withoutMotion)
        case .close: MarkFrame(pose: MarkPose.resting(for: .negotiating).withoutMotion)
        case .logo: .logo
        }
    }
}
