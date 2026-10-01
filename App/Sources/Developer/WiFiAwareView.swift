#if DEBUG
// The Developer section is in Debug builds only (ADR 0015 decision 5).
import StarlingCore
import StarlingFeatures
import StarlingWiFiAware
import SwiftUI

/// Lane E2's device checklist screen: pair phones over Wi-Fi Aware in the
/// OS, see the system's paired devices, and test the app's links to each
/// Starling friend (docs/requests/E2.md section 3). The links are the app's
/// own (lane E1's secure transports), so only Starling-paired friends
/// appear, and only once their key is proven.
struct WiFiAwareView: View {
    let app: AppModel
    @State private var devices = WiFiAwarePairedDevices()

    var body: some View {
        List {
            if WiFiAwareSupport.isSupported {
                Section {
                    WiFiAwarePairingButtons()
                } header: {
                    Text("Pair")
                } footer: {
                    Text("One phone lets a friend find it; the other finds it. Remove pairings in Settings.")
                }

                Section("Paired devices") {
                    if devices.isUnavailable {
                        Text("The paired-device list isn't available. Check the Wi-Fi Aware entitlement.").foregroundStyle(.secondary)
                    } else if devices.devices.isEmpty {
                        Text("None yet").foregroundStyle(.secondary)
                    }
                    ForEach(devices.devices) { Text($0.name) }
                }
                .task { await devices.track() }
            } else {
                Section {
                    Text("This iPhone can't use Wi-Fi Aware. It needs an iPhone 12 or later, and it doesn't run in the Simulator.")
                        .foregroundStyle(.secondary)
                }
            }
            if let link = app.link { linkSection(link) }
        }
        .navigationTitle("Wi-Fi Aware")
    }

    @ViewBuilder private func linkSection(_ link: LinkTestModel) -> some View {
        Section {
            if link.peers.isEmpty {
                Text("No friends linked yet. Pair in the Friends tab, then keep Starling open on both phones.").foregroundStyle(.secondary)
            }
            ForEach(link.peers) { peer in
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(peer.isConnected ? .green : .secondary)
                        .accessibilityLabel(peer.isConnected ? "Connected" : "Not connected")
                    VStack(alignment: .leading) {
                        Text(peer.name)
                        if let rtt = peer.lastRoundTrip {
                            Text("Round trip \(rtt.formatted(.units(allowed: [.milliseconds], width: .abbreviated)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = peer.lastError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    Button(peer.isWaiting ? "Waiting" : "Round trip") { Task { await link.ping(peer.id) } }
                        .buttonStyle(.bordered)
                        .disabled(!peer.isConnected || peer.isWaiting)
                }
            }
        } header: {
            Text("Link")
        } footer: {
            Text("A round trip sends only this phone's agent card, over the app's secure links.")
        }
    }
}

#endif
