import Foundation
import StarlingCore

/// The mutual reveal building block over time (brief 2.7): one PSI token per
/// free half-hour, padded with random tokens to a fixed size.
///
/// Each skill names its own `namespace`, so tokens from one skill never
/// intersect another's. Padding hides how much free time the owner has,
/// since set sizes are visible in DH-based PSI (brief 3.9). Nothing else
/// about the owner goes into the set.
public struct SlotTokenSet: Sendable {
    /// Slot length. Both phones must use the same grid, so this is part of
    /// the token format.
    public static let slotMinutes: Int64 = 30
    /// Every set has exactly this many elements, and a peer's larger set is
    /// rejected. Twelve hours of half-hours covers "free tonight" while
    /// keeping what one run can probe small.
    public static let setSize = 24
    /// How far ahead the scan for free slots looks.
    static let horizonMinutes: Int64 = 14 * 24 * 60
    /// Longest namespace, so every token fits a `PSIElement`.
    public static let maxNamespaceCharacters = 16

    public let namespace: String
    /// Free slots, earliest first. At most `setSize`.
    public let slots: [TimeSlot]
    /// `slots` as tokens, plus padding.
    public let elements: Set<PSIElement>
    private let slotsByToken: [PSIElement: TimeSlot]

    /// - Parameters:
    ///   - namespace: The skill's token prefix, such as `down_for/v1`: 1 to
    ///     16 of `a-z 0-9 _ /`. Part of the wire format.
    ///   - constraints: The owner's rules. A slot qualifies when it breaks no
    ///     time limit (`within`, `dailyWindow`).
    ///   - now: Slots start at or after this, on the next grid boundary.
    ///   - expiresAt: Slots end at or before this.
    public init(namespace: String, constraints: ConstraintSet, now: Date, expiresAt: Date, timeZone: TimeZone) {
        precondition(Self.isValid(namespace: namespace), "invalid slot token namespace")
        self.namespace = namespace
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
        slotsByToken = Dictionary(uniqueKeysWithValues: found.map { (Self.token(for: $0, namespace: namespace), $0) })
        var elements = Set(slotsByToken.keys)
        var generator = SystemRandomNumberGenerator()
        while elements.count < Self.setSize {
            let noise = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
            // Force-try is safe: at most 9 + 16 + 5 + 32 = 62 bytes.
            elements.insert(try! PSIElement(Data("starling/\(namespace)/pad/\(noise)".utf8)))
        }
        self.elements = elements
    }

    /// The canonical token for one grid slot. Identical on every phone.
    public static func token(for slot: TimeSlot, namespace: String) -> PSIElement {
        // Force-try is safe: at most 9 + 16 + 6 + 19 = 50 bytes.
        try! PSIElement(Data("starling/\(namespace)/slot/\(slot.startMinute)".utf8))
    }

    public func token(for slot: TimeSlot) -> PSIElement { Self.token(for: slot, namespace: namespace) }

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

    static func isValid(namespace: String) -> Bool {
        (1...maxNamespaceCharacters).contains(namespace.unicodeScalars.count)
            && namespace.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "/" }
    }
}
