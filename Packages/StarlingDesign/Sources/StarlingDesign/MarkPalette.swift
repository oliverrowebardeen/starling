import Foundation
import SwiftUI

/// An sRGB color token.
public struct MarkColor: Equatable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(hex: UInt32) {
        red = UInt8((hex >> 16) & 0xFF)
        green = UInt8((hex >> 8) & 0xFF)
        blue = UInt8(hex & 0xFF)
    }

    public var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    /// WCAG 2.x relative luminance.
    public var relativeLuminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2.x contrast ratio, from 1 to 21.
    public func contrastRatio(against other: MarkColor) -> Double {
        let high = max(relativeLuminance, other.relativeLuminance)
        let low = min(relativeLuminance, other.relativeLuminance)
        return (high + 0.05) / (low + 0.05)
    }
}

/// The brand colors. Shape A is you, shape B is the other person.
public struct MarkPalette: Equatable, Sendable {
    public let shapeA: MarkColor
    public let shapeB: MarkColor
    /// The app icon background. The status mark itself draws no background.
    public let background: MarkColor
    /// The light that fills the gap on a match (from the owner's motion reference).
    public let glow: MarkColor

    public static let light = MarkPalette(
        shapeA: MarkColor(hex: 0x1F4FE0), shapeB: MarkColor(hex: 0x5F80EE),
        background: MarkColor(hex: 0xFAF9F6), glow: MarkColor(hex: 0x9DB8FF)
    )
    public static let dark = MarkPalette(
        shapeA: MarkColor(hex: 0x5B85FF), shapeB: MarkColor(hex: 0x3F63D6),
        background: MarkColor(hex: 0x141418), glow: MarkColor(hex: 0xFFFFFF)
    )

    public static func forScheme(_ scheme: ColorScheme) -> MarkPalette {
        scheme == .dark ? .dark : .light
    }
}
