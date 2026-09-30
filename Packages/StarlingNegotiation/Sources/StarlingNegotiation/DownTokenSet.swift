import Foundation
import StarlingCore

/// The PSI set for one Down intent: one token per free half-hour, padded with
/// random tokens to a fixed size (ADR 0120).
///
/// The owner's level (`down` or `maybe`) is not an input, so both levels give
/// the same tokens and the PSI run cannot reveal it. Padding hides how much
/// free time the owner has, since set sizes are visible in DH-based PSI
/// (brief 3.9).
public struct DownTokenSet: Sendable {
    /// Slot length. Both phones must use the same grid, so this is part of
    /// the token format.
    public static let slotMinutes: Int64 = 30
    /// Every set has exactly this many elements, and a peer's larger set is
    /// rejected. Twelve hours of half-hours covers "free tonight" while
    /// keeping what one run can probe small.
    public static let setSize = 24
    /// How far ahead the scan for free slots looks.
    static let horizonMinutes: Int64 = 14 * 24 * 60
    private static let slotPrefix = "starling/down/v1/slot/"
    private static let padPrefix = "starling/down/v1/pad/"

    /// Free slots, earliest first. At most `setSize`.
    public let slots: [TimeSlot]
    /// `slots` as tokens, plus padding.
    public let elements: Set<PSIElement>
    private let slotsByToken: [PSIElement: TimeSlot]

    /// - Parameters:
    ///   - constraints: The owner's rules. A slot qualifies when it breaks no
    ///     time limit (`within`, `dailyWindow`).
    ///   - now: Slots start at or after this, on the next grid boundary.
    ///   - expiresAt: Slots end at or before this.
    public init(constraints: ConstraintSet, now: Date, expiresAt: Date, timeZone: TimeZone) {
        let grid = Self.slotMinutes
        let nowMinute = Int64((now.timeIntervalSince1970 / 60).rounded(.up))
        let first = (nowMinute + grid - 1) / grid * grid
        let last = min(Int64((expiresAt.timeIntervalSince1970 / 60).rounded(.down)), first + Self.horizonMinutes)

        var found: [TimeSlot] = []
        var start = first
        while start + grid <= last, found.count < Self.setSize {
            if let slot = try? TimeSlot(startMinute: start, endMinute: start + grid),
               let terms = try? Terms([.time: .slots([slot])]),
               constraints.violations(of: terms, timeZone: timeZone).isEmpty {
                found.append(slot)
            }
            start += grid
        }

        slots = found
        slotsByToken = Dictionary(uniqueKeysWithValues: found.map { (Self.token(for: $0), $0) })
        var elements = Set(slotsByToken.keys)
        var generator = SystemRandomNumberGenerator()
        while elements.count < Self.setSize {
            let noise = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
            // Force-try is safe: the prefix plus 32 hex digits is 53 bytes.
            elements.insert(try! PSIElement(Data((Self.padPrefix + noise).utf8)))
        }
        self.elements = elements
    }

    /// The canonical token for one grid slot. Identical on every phone.
    public static func token(for slot: TimeSlot) -> PSIElement {
        // Force-try is safe: the prefix plus at most 19 digits is under 64 bytes.
        try! PSIElement(Data((slotPrefix + String(slot.startMinute)).utf8))
    }

    /// Our slots among `elements`, earliest first. Anything we did not put in
    /// the set (a dishonest reply) is ignored.
    public func slots(in elements: Set<PSIElement>) -> [TimeSlot] {
        elements.compactMap { slotsByToken[$0] }.sorted()
    }

    /// Both roles use this: learn the shared slots, and refuse a peer set
    /// larger than ours.
    public static func psiConfiguration() throws -> PSIConfiguration {
        try PSIConfiguration(output: .intersection, maxPeerSetSize: setSize, maxLocalSetSize: setSize)
    }
}
