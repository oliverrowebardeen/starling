import StarlingCore
import StarlingFeatures
import StarlingWiFiAware
import SwiftUI

/// Lane E2's device checklist screen: pair over Wi-Fi Aware, see paired
/// devices, and test the link to each peer (docs/requests/E2.md section 3).
/// Links are encrypted between OS-paired devices, but the peer IDs here are
/// unverified until lane E1's secure channel lands.
struct WiFiAwareView: View {
    let app: AppModel
    @State private var devices = WiFiAwarePairedDevices()
    @State private var link: LinkTestModel?

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

                if let link { linkSection(link) }
            } else {
                Section {
                    Text("This iPhone can't use Wi-Fi Aware. It needs an iPhone 12 or later, and it doesn't run in the Simulator.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Wi-Fi Aware")
        .task {
            guard link == nil, let transport = LiveServices.wifiAwareTransport(), let policy = app.policy else { return }
            let friends = app.friends?.friends ?? []
            let model = LinkTestModel(
                transport: transport,
                policy: policy,
                consent: app.consent,
                observer: app.services.auditLog,
                // Cannot throw: one protocol version and one capability are within limits.
                card: try! AgentCard(model: app.services.agent?.descriptor.locality ?? .none, capabilities: [.down]),
                name: { peer in friends.first { $0.id == peer }?.nickname }
            )
            link = model
            await model.start()
        }
        .onDisappear {
            let model = link
            link = nil
            Task { await model?.stop() }
        }
    }

    @ViewBuilder private func linkSection(_ link: LinkTestModel) -> some View {
        Section {
            LabeledContent("This phone", value: link.localPeer.short)
            switch link.status {
            case .idle: Text("Starting...").foregroundStyle(.secondary)
            case .running: EmptyView()
            case .failed(let message): Text(message).foregroundStyle(.red)
            }
            if link.peers.isEmpty {
                Text("No phones linked yet. Keep this screen open on both phones.").foregroundStyle(.secondary)
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
            Text("A round trip sends only this phone's agent card. Peer IDs are not verified until secure pairing lands.")
        }
    }
}

/// Lane E2's DeviceDiscoveryUI views, shown only where Wi-Fi Aware runs.
struct WiFiAwarePairingButtons: View {
    var body: some View {
        #if canImport(DeviceDiscoveryUI) && canImport(WiFiAware) && os(iOS) && !targetEnvironment(macCatalyst)
        if WiFiAwareSupport.isSupported {
            WiFiAwarePairingView {
                Label("Let a friend find this phone", systemImage: "dot.radiowaves.left.and.right")
            } fallback: {
                Text("Pairing isn't available on this iPhone.").foregroundStyle(.secondary)
            }
            WiFiAwareDevicePicker {
                Label("Find a friend's phone", systemImage: "magnifyingglass")
            } fallback: {
                Text("Pairing isn't available on this iPhone.").foregroundStyle(.secondary)
            }
        }
        #endif
    }
}
