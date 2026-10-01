#if DEBUG
// Phase 0 spike: unauthenticated, unencrypted, allow-all policy from
// StarlingFakes. Debug builds only (ADR 0140).
import SwiftUI

struct NearbyView: View {
    @State private var session = NearbySession()

    var body: some View {
        List {
            Section {
                LabeledContent("You", value: session.me.short)
                switch session.status {
                case .idle:
                    Button("Start") { Task { await session.start() } }
                case .running:
                    Button("Stop", role: .destructive) { Task { await session.stop() } }
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                    Button("Retry") { Task { await session.start() } }
                }
            } footer: {
                Text("Both phones need this screen open with Start tapped. They don't need to share a Wi-Fi network.")
            }

            Section("Nearby phones") {
                if session.peers.isEmpty {
                    Text(session.status == .running ? "Looking..." : "Not running").foregroundStyle(.secondary)
                }
                ForEach(session.peers, id: \.self) { peer in
                    HStack {
                        Text(peer.short).monospaced()
                        Spacer()
                        Button("Send proposal") { Task { await session.sendProposal(to: peer) } }
                            .buttonStyle(.bordered)
                    }
                }
            }

            Section("Log") {
                ForEach(session.log) { line in
                    VStack(alignment: .leading) {
                        Text(line.text).font(.callout.monospaced())
                        Text(line.time.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Nearby")
        .onDisappear { Task { await session.stop() } }
    }
}
#endif
