import CoreGraphics
import SwiftUI
@testable import StarlingDesign
import Testing

/// Renders the mark off screen and reads pixels back, to prove the overlap is
/// cut out by the fill rule (alpha 0) and not painted over.
@MainActor
@Suite struct MarkRenderingTests {
    static let side: CGFloat = 256

    struct Pixel: Equatable, CustomStringConvertible {
        let red, green, blue, alpha: Int
        var description: String { String(format: "#%02X%02X%02X alpha %d", red, green, blue, alpha) }

        func matches(_ color: MarkColor, tolerance: Int = 2) -> Bool {
            alpha == 255
                && abs(red - Int(color.red)) <= tolerance
                && abs(green - Int(color.green)) <= tolerance
                && abs(blue - Int(color.blue)) <= tolerance
        }
    }

    /// Renders `view` into an sRGB bitmap and returns a pixel reader in unit coordinates.
    func render(_ view: some View) throws -> (CGPoint) -> Pixel {
        let renderer = ImageRenderer(content: view.frame(width: Self.side, height: Self.side))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // Copy out: the context owns that memory and goes away when this function returns.
        let data = Array(UnsafeBufferPointer(start: bytes, count: width * height * 4))
        let rect = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)
        return { unit in
            let point = MarkGeometry.point(unit, in: rect)
            // Bitmap memory is top row first, matching SwiftUI's y-down coordinates.
            let offset = (Int(point.y) * width + Int(point.x)) * 4
            return Pixel(red: Int(data[offset]), green: Int(data[offset + 1]), blue: Int(data[offset + 2]), alpha: Int(data[offset + 3]))
        }
    }

    /// Points well inside only one shape in the logo pose.
    static let insideAOnly = CGPoint(x: -20, y: -22)
    static let insideBOnly = CGPoint(x: 20, y: 22)

    @Test func logoPoseKnocksOutTheOverlapInLightMode() throws {
        let pixel = try render(MarkGlyph(frame: .logo, palette: .light))
        #expect(pixel(MarkFrame.logo.overlapCenter).alpha == 0)
        #expect(pixel(Self.insideAOnly).matches(MarkPalette.light.shapeA), "A is \(pixel(Self.insideAOnly))")
        #expect(pixel(Self.insideBOnly).matches(MarkPalette.light.shapeB), "B is \(pixel(Self.insideBOnly))")
        // Outside both shapes the mark draws nothing: it has no background of its own.
        #expect(pixel(CGPoint(x: 40, y: -40)).alpha == 0)
    }

    @Test func glyphPicksDarkColorsFromTheEnvironment() throws {
        let pixel = try render(StatusMarkGlyph(.logo).environment(\.colorScheme, .dark))
        #expect(pixel(.zero).alpha == 0)
        #expect(pixel(Self.insideAOnly).matches(MarkPalette.dark.shapeA), "A is \(pixel(Self.insideAOnly))")
        #expect(pixel(Self.insideBOnly).matches(MarkPalette.dark.shapeB), "B is \(pixel(Self.insideBOnly))")
    }

    /// The knockout is a rule, so it follows the shapes wherever they are.
    @Test func overlapIsTransparentInAnyPose() throws {
        let transition = MarkTransition(resting: .idle).retargeted(to: .negotiating, at: 0)
        for time in [0.5, 0.7, 3.3] {
            let frame = transition.frame(at: time, reduceMotion: false)
            try #require(frame.shapesOverlap)
            let pixel = try render(MarkGlyph(frame: frame, palette: .light))
            #expect(pixel(frame.overlapCenter).alpha == 0, "at \(time)")
            let aOnly = CGPoint(x: frame.centerA.x - 12, y: frame.centerA.y - 14)
            #expect(pixel(aOnly).matches(MarkPalette.light.shapeA), "at \(time): \(pixel(aOnly))")
        }
    }

    @Test func matchLightFillsOnlyTheGap() throws {
        var frame = MarkFrame.logo
        frame.glow = 1
        let pixel = try render(MarkGlyph(frame: frame, palette: .light))
        #expect(pixel(.zero).matches(MarkPalette.light.glow), "gap is \(pixel(.zero))")
        #expect(pixel(Self.insideAOnly).matches(MarkPalette.light.shapeA))
        #expect(pixel(Self.insideBOnly).matches(MarkPalette.light.shapeB))
    }

    @Test func fadedPartnerIsTranslucent() throws {
        let frame = MarkFrame(pose: MarkPose.resting(for: .noMatch))
        let pixel = try render(MarkGlyph(frame: frame, palette: .light))
        let partner = pixel(frame.centerB)
        #expect(partner.alpha > 0 && partner.alpha < 128, "partner is \(partner)")
        #expect(pixel(frame.centerA).matches(MarkPalette.light.shapeA))
    }
}
