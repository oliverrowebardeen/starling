import SwiftUI

/// Draws one frame of the mark.
///
/// The overlap is cut live with the even-odd fill rule: each shape is masked by
/// "everything except the other shape", so the gap is transparent at any
/// position. There is no stored cutout. No glass effect either: glass shapes
/// merge when they get close, which would fill the gap.
///
/// Built from shapes rather than `Canvas` so it also renders where only static
/// SwiftUI views are allowed.
public struct MarkGlyph: View {
    public let frame: MarkFrame
    public let palette: MarkPalette

    public init(frame: MarkFrame, palette: MarkPalette) {
        self.frame = frame
        self.palette = palette
    }

    public var body: some View {
        let shapeA = MarkShape(center: frame.centerA, scale: frame.scaleA)
        let shapeB = MarkShape(center: frame.centerB, scale: 1)
        ZStack {
            shapeA.fill(palette.shapeA.color)
                .mask(EverythingExcept(hole: shapeB).fill(style: FillStyle(eoFill: true)))
            shapeB.fill(palette.shapeB.color)
                .mask(EverythingExcept(hole: shapeA).fill(style: FillStyle(eoFill: true)))
                .opacity(frame.opacityB)
            if frame.glow > 0 {
                shapeB.fill(palette.glow.color)
                    .clipShape(shapeA)
                    .opacity(frame.glow)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// A still mark in the current color scheme, for places that cannot animate.
public struct StatusMarkGlyph: View {
    public let pose: StaticMarkPose
    @Environment(\.colorScheme) private var colorScheme

    public init(_ pose: StaticMarkPose) {
        self.pose = pose
    }

    public var body: some View {
        MarkGlyph(frame: pose.frame, palette: .forScheme(colorScheme))
    }
}

struct MarkShape: Shape {
    var center: CGPoint
    var scale: CGFloat

    func path(in rect: CGRect) -> Path {
        MarkGeometry.shapePath(center: center, scale: scale, in: rect)
    }
}

/// A large rectangle with `hole` inside it. Filled even-odd, the hole stays empty.
struct EverythingExcept: Shape {
    var hole: MarkShape

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -rect.width, dy: -rect.height))
        path.addPath(hole.path(in: rect))
        return path
    }
}

#Preview("Still poses") {
    VStack(spacing: 24) {
        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            HStack(spacing: 24) {
                ForEach(StaticMarkPose.allCases, id: \.self) { pose in
                    StatusMarkGlyph(pose).frame(width: 64, height: 64)
                }
            }
            .padding(16)
            .background(MarkPalette.forScheme(scheme).background.color)
            .environment(\.colorScheme, scheme)
        }
    }
    .padding()
}

#Preview("Dynamic Island sizes") {
    HStack(spacing: 16) {
        ForEach(StaticMarkPose.allCases, id: \.self) { pose in
            StatusMarkGlyph(pose).frame(width: 22, height: 22)
        }
    }
    .padding(12)
    .background(.black, in: Capsule())
    .environment(\.colorScheme, .dark)
    .padding()
}
