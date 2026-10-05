#if DEBUG
// The Developer section is in Debug builds only (ADR 0015 decision 5).
import StarlingFeatures
import SwiftUI

/// Every pairing step and Wi-Fi Aware link event since launch (ADR 0260),
/// newest last, so a pairing that fails on two phones says where it stopped.
/// No keys, nonces, or codes are ever recorded.
struct PairingLogView: View {
    let log: PairingLog

    var body: some View {
        List {
            if log.lines.isEmpty {
                Text("Nothing yet. Open Friends › Add friend on both phones.").foregroundStyle(.secondary)
            }
            ForEach(log.lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: line.text).font(.footnote.monospaced())
                    Text(verbatim: "\(line.date.formatted(date: .omitted, time: .standard)) · \(line.source)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Pairing log")
        .toolbar {
            ShareLink(item: log.text)
            Button("Clear", role: .destructive) { log.clear() }
        }
    }
}
#endif
