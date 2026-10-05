import Foundation
import Observation

/// The Debug pairing log (ADR 0260): one line per pairing step and link
/// event, shown in the Developer section, so a failed pairing on a phone
/// says where it stopped. Lines name steps, messages, failures, short peer
/// IDs, and local device numbers, never keys, nonces, or codes. Release
/// builds never create one.
@MainActor
@Observable
public final class PairingLog {
    public struct Line: Identifiable, Hashable, Sendable {
        public let id: Int
        public let date: Date
        public let source: String
        public let text: String
    }

    public static let capacity = 400

    public private(set) var lines: [Line] = []
    private var next = 0

    public init() {}

    public func append(_ text: String, source: String, at date: Date = Date()) {
        lines.append(Line(id: next, date: date, source: source, text: text))
        next += 1
        if lines.count > Self.capacity { lines.removeFirst(lines.count - Self.capacity) }
    }

    public func clear() { lines = [] }

    /// A closure any actor can call, for the transport and pairing hooks.
    public nonisolated func recorder(source: String) -> @Sendable (String) -> Void {
        { [weak self] text in
            let date = Date()
            Task { @MainActor in self?.append(text, source: source, at: date) }
        }
    }

    /// The whole log as text, for sharing from the Developer section.
    public var text: String {
        lines.map { "\($0.date.formatted(date: .omitted, time: .standard)) [\($0.source)] \($0.text)" }.joined(separator: "\n")
    }
}
