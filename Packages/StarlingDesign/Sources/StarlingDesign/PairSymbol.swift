import SwiftUI

/// One friend's colors for the Overlap mark, in light and dark.
public struct PairColors: Equatable, Hashable, Sendable {
    public let name: String
    public let light: (shapeA: MarkColor, shapeB: MarkColor)
    public let dark: (shapeA: MarkColor, shapeB: MarkColor)

    public init(name: String, light: (UInt32, UInt32), dark: (UInt32, UInt32)) {
        self.name = name
        self.light = (MarkColor(hex: light.0), MarkColor(hex: light.1))
        self.dark = (MarkColor(hex: dark.0), MarkColor(hex: dark.1))
    }

    /// The pair as a full mark palette, on the brand background.
    public func palette(for scheme: ColorScheme) -> MarkPalette {
        let brand = MarkPalette.forScheme(scheme)
        let shapes = scheme == .dark ? dark : light
        return MarkPalette(shapeA: shapes.shapeA, shapeB: shapes.shapeB, background: brand.background, glow: brand.glow)
    }

    public static func == (lhs: PairColors, rhs: PairColors) -> Bool {
        lhs.name == rhs.name && lhs.light == rhs.light && lhs.dark == rhs.dark
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

/// The curated color pairs friends' symbols come from (DESIGN.md section 4).
///
/// Every shape keeps at least 3:1 against the brand background in light and
/// dark, which a test checks. The brand blue pair is left out: it is the
/// owner's own symbol.
public enum PairPalette {
    public static let pairs: [PairColors] = [
        PairColors(name: "teal", light: (0x0F766E, 0x2A9D8F), dark: (0x2DD4BF, 0x14B8A6)),
        PairColors(name: "violet", light: (0x6D28D9, 0x8B5CF6), dark: (0xA78BFA, 0x8B5CF6)),
        PairColors(name: "orange", light: (0xB45309, 0xD97706), dark: (0xFBBF24, 0xF59E0B)),
        PairColors(name: "rose", light: (0xBE123C, 0xE11D48), dark: (0xFB7185, 0xF43F5E)),
        PairColors(name: "green", light: (0x15803D, 0x2F9E44), dark: (0x4ADE80, 0x22C55E)),
        PairColors(name: "magenta", light: (0xA21CAF, 0xC026D3), dark: (0xE879F9, 0xD946EF)),
        PairColors(name: "cyan", light: (0x0E7490, 0x0891B2), dark: (0x22D3EE, 0x06B6D4)),
        PairColors(name: "brown", light: (0x8A5A2B, 0xA8743F), dark: (0xD6A56B, 0xB98546)),
        PairColors(name: "indigo", light: (0x4338CA, 0x6366F1), dark: (0x818CF8, 0x6366F1)),
        PairColors(name: "olive", light: (0x4D7C0F, 0x588A0C), dark: (0xA3E635, 0x84CC16)),
    ]

    /// The owner's own symbol: the brand pair.
    public static let own = PairColors(name: "brand", light: (0x1F4FE0, 0x5F80EE), dark: (0x5B85FF, 0x3F63D6))

    /// The pair for a seed, the same every time. The app passes a friend's
    /// PeerID, which is a SHA-256 of their key, so the first eight bytes
    /// are already uniform and a peer cannot pick its own symbol without
    /// choosing a key for it. An empty seed gets the first pair.
    public static func colors(for seed: some Sequence<UInt8>) -> PairColors {
        var value: UInt64 = 0
        for byte in seed.prefix(8) { value = value << 8 | UInt64(byte) }
        return pairs[Int(value % UInt64(pairs.count))]
    }
}

/// A friend's pair symbol: the Overlap mark in the friend's own colors
/// (DESIGN.md section 4). Decorative, not a security signal: the code check
/// at pairing verifies a friend, and the symbol only helps recognition.
/// Hidden from VoiceOver, because the friend's name is always next to it.
public struct PairSymbol: View {
    private let colors: PairColors
    @Environment(\.colorScheme) private var colorScheme

    /// A friend's symbol, derived from their PeerID bytes.
    public init(seed: some Sequence<UInt8>) {
        colors = PairPalette.colors(for: seed)
    }

    /// The owner's own symbol, in the brand pair.
    public static var own: PairSymbol { PairSymbol(colors: PairPalette.own) }

    init(colors: PairColors) {
        self.colors = colors
    }

    public var body: some View {
        MarkGlyph(frame: StaticMarkPose.logo.frame, palette: colors.palette(for: colorScheme))
            .accessibilityHidden(true)
    }
}

#Preview("Pair symbols") {
    VStack(spacing: 24) {
        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 6), spacing: 12) {
                PairSymbol.own.frame(width: 44, height: 44)
                ForEach(PairPalette.pairs, id: \.name) { pair in
                    PairSymbol(colors: pair).frame(width: 44, height: 44)
                }
            }
            .padding(16)
            .background(MarkPalette.forScheme(scheme).background.color)
            .environment(\.colorScheme, scheme)
        }
    }
    .padding()
}
