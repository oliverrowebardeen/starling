#if DEBUG
// The Developer section is in Debug builds only (ADR 0015 decision 5).
import StarlingCore
import StarlingFeatures
import StarlingPolicy
import SwiftUI

/// Lane G's local audit log: every message this phone handed to a transport
/// since launch, newest first. It records kinds of values, never the values.
struct AuditLogView: View {
    let log: InMemoryAuditLog
    let friends: [PairedPeer]
    @State private var entries: [AuditEntry] = []
    private let formatter = ValueFormatter()

    var body: some View {
        List {
            if entries.isEmpty {
                Text("Nothing has been sent since launch.").foregroundStyle(.secondary)
            }
            ForEach(entries.reversed(), id: \.message) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(entry.kind.rawValue) to \(name(for: entry.recipient))").font(.headline)
                    Text(entry.sentAt.date.formatted(date: .omitted, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(entry.items.enumerated()), id: \.offset) { _, item in
                        Text([item.issue.map(formatter.issueName), item.valueKind?.rawValue].compactMap(\.self).joined(separator: ": "))
                            .font(.subheadline)
                    }
                }
            }
        }
        .navigationTitle("Audit log")
        .toolbar {
            Button("Clear", role: .destructive) {
                Task {
                    await log.removeAll()
                    entries = []
                }
            }
        }
        .task { entries = await log.entries() }
        .refreshable { entries = await log.entries() }
    }

    private func name(for peer: PeerID) -> String {
        friends.first { $0.id == peer }?.nickname ?? peer.short
    }
}
#endif
