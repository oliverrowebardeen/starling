import Foundation
import StarlingCore

/// The PSI set for one Down intent (ADR 0120): `SlotTokenSet` in the
/// Phase 1 namespace, `down/v1`.
///
/// The owner's level (`down` or `maybe`) is not an input, so both levels give
/// the same tokens and the PSI run cannot reveal it.
public struct DownTokenSet: Sendable {
    public static let slotMinutes = SlotTokenSet.slotMinutes
    public static let setSize = SlotTokenSet.setSize
    static let namespace = "down/v1"

    private let base: SlotTokenSet

    /// Free slots, earliest first. At most `setSize`.
    public var slots: [TimeSlot] { base.slots }
    /// `slots` as tokens, plus padding.
    public var elements: Set<PSIElement> { base.elements }

    public init(constraints: ConstraintSet, now: Date, expiresAt: Date, timeZone: TimeZone) {
        base = SlotTokenSet(namespace: Self.namespace, constraints: constraints, now: now, expiresAt: expiresAt, timeZone: timeZone)
    }

    /// The canonical token for one grid slot. Identical on every phone.
    public static func token(for slot: TimeSlot) -> PSIElement { SlotTokenSet.token(for: slot, namespace: namespace) }

    /// Our slots among `elements`, earliest first.
    public func slots(in elements: Set<PSIElement>) -> [TimeSlot] { base.slots(in: elements) }

    public static func psiConfiguration() throws -> PSIConfiguration { try SlotTokenSet.psiConfiguration() }
}
