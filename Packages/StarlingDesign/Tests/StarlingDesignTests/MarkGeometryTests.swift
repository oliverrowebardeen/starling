import CoreGraphics
import Foundation
@testable import StarlingDesign
import Testing

@Suite struct MarkGeometryTests {
    /// Tangent points of the straight edges in the app icon's layers, in the
    /// 1024 px icon canvas. Copied from App/Resources/Starling.icon/Assets/A.svg
    /// and B.svg. If the icon changes, this test says the mark no longer matches it.
    static let iconAnchors: [(unit: CGPoint, icon: CGPoint)] = [
        (CGPoint(x: -16, y: -36), CGPoint(x: 488.026, y: 165.897)),  // A: top edge, left end
        (CGPoint(x: -4, y: -36), CGPoint(x: 587.330, y: 202.041)),   // A: top edge, right end
        (CGPoint(x: -30, y: -22), CGPoint(x: 330.004, y: 239.584)),  // A: left edge, top end
        (CGPoint(x: 16, y: 36), CGPoint(x: 535.974, y: 858.103)),    // B: bottom edge, right end
        (CGPoint(x: 30, y: 22), CGPoint(x: 693.996, y: 784.416)),    // B: right edge, bottom end
    ]

    @Test func logoPoseLinesUpWithTheAppIconLayers() {
        let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        for (unit, icon) in Self.iconAnchors {
            let mapped = MarkGeometry.point(unit, in: canvas)
            #expect(abs(mapped.x - icon.x) < 0.05, "x for \(unit)")
            #expect(abs(mapped.y - icon.y) < 0.05, "y for \(unit)")
        }
        // Those anchors are corners of shapes centered where the logo pose puts them.
        #expect(MarkFrame.logo.centerA == CGPoint(x: -10, y: -8))
        #expect(MarkFrame.logo.centerB == CGPoint(x: 10, y: 8))
    }

    @Test func everyMatchRestsAsTheLogo() {
        #expect(MarkPose.resting(for: .match) == .logo)
        #expect(StaticMarkPose.logo.frame == .logo)
        let settled = MarkTransition(resting: .negotiating).retargeted(to: .match, at: 100)
        #expect(settled.frame(at: 100 + 60, reduceMotion: false) == .logo)
        #expect(settled.frame(at: 100 + 60, reduceMotion: true) == .logo)
    }

    @Test func idleIsApartAndNegotiatingOpensAGap() {
        #expect(!MarkFrame(pose: .resting(for: .idle)).shapesOverlap)
        #expect(!MarkFrame(pose: .resting(for: .noMatch)).shapesOverlap)
        #expect(MarkFrame(pose: .resting(for: .negotiating)).shapesOverlap)
        #expect(MarkFrame.logo.shapesOverlap)
        #expect(!StaticMarkPose.apart.frame.shapesOverlap)
        #expect(StaticMarkPose.close.frame.shapesOverlap)
    }

    @Test func negotiatingSitsBetweenApartAndTheLogo() {
        let apart = MarkPose.resting(for: .idle).separation
        let close = MarkPose.resting(for: .negotiating).separation
        let logo = MarkPose.logo.separation
        #expect(apart.dx > close.dx && close.dx > logo.dx)
        #expect(apart.dy > close.dy && close.dy > logo.dy)
    }

    @Test func overlapCenterIsInsideBothShapesAndNeitherAlone() {
        let logo = MarkFrame.logo
        #expect(logo.overlapCenter == .zero)
        #expect(MarkGeometry.contains(logo.overlapCenter, shapeCenter: logo.centerA))
        #expect(MarkGeometry.contains(logo.overlapCenter, shapeCenter: logo.centerB))
        #expect(MarkGeometry.contains(CGPoint(x: -20, y: -22), shapeCenter: logo.centerA))
        #expect(!MarkGeometry.contains(CGPoint(x: -20, y: -22), shapeCenter: logo.centerB))
        // Rounded corners: the bounding box corner is outside the shape.
        #expect(!MarkGeometry.contains(CGPoint(x: -29.5, y: -35.5), shapeCenter: logo.centerA))
    }

    @Test func everyStateStaysInsideTheCanvasWhileItMoves() {
        let half = MarkGeometry.canvasUnits / 2
        for state in MarkState.allCases {
            let transition = MarkTransition(resting: .idle).retargeted(to: state, at: 0)
            for step in 0...400 {
                let time = Double(step) * 0.05
                let frame = transition.frame(at: time, reduceMotion: false)
                for (center, scale) in [(frame.centerA, frame.scaleA), (frame.centerB, 1)] {
                    for corner in MarkGeometry.cornerCenters(center: center, scale: scale) {
                        // Rotate into the canvas frame and add the corner radius.
                        let p = corner.applying(CGAffineTransform(rotationAngle: MarkGeometry.rotation.radians))
                        let reach = MarkGeometry.cornerRadius * scale
                        #expect(abs(p.x) + reach <= half, "\(state) at \(time)")
                        #expect(abs(p.y) + reach <= half, "\(state) at \(time)")
                    }
                }
            }
        }
    }
}
