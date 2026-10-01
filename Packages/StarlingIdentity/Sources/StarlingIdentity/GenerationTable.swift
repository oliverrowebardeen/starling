import StarlingCore

/// Per-peer generation numbers with bounded memory, used to tell whether
/// something about a peer changed across an await (ADR 0100 decision 11).
///
/// Values come from one counter that only grows, so a value is never
/// reused. Past `capacity` entries the oldest is evicted, and peers without
/// an entry read `floor`, which every eviction raises above every value
/// handed out so far. A caller that read a value before an eviction
/// therefore never reads the same value after it: eviction can only make a
/// comparison fail (safe, the caller retries later), never pass wrongly.
struct GenerationTable: Sendable {
    let capacity: Int
    private var values: [PeerID: UInt64] = [:]
    private var floor: UInt64 = 0
    private var next: UInt64 = 1

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var count: Int { values.count }

    func value(of peer: PeerID) -> UInt64 {
        values[peer] ?? floor
    }

    /// Gives `peer` a value no caller has seen before.
    mutating func bump(_ peer: PeerID) {
        values[peer] = next
        next += 1
        guard values.count > capacity, let oldest = values.min(by: { $0.value < $1.value })?.key else { return }
        values.removeValue(forKey: oldest)
        floor = next
        next += 1
    }
}
