import StarlingCore
import StarlingFeatures
import StarlingWiFiAware
import SwiftUI

/// In-person pairing: both phones show a code, both people check it matches,
/// then name the friend (brief 2.5 step 2, ADR 0003).
struct PairingView: View {
    @State var model: PairingModel
    let onDone: () -> Void

    var body: some View {
        Form {
            switch model.phase {
            case .idle:
                Section {
                    DeviceDiscoverySlot { device in
                        Task { await model.pickedDevice(id: device.id, name: device.name) }
                    }
                } footer: {
                    Text("Pairing only works with both of you together. On Wi-Fi Aware phones, let the system pair the two phones first.")
                }
                Section {
                    if model.candidates.isEmpty {
                        Text("Looking for nearby phones that aren't paired with Starling yet...").foregroundStyle(.secondary)
                    }
                    ForEach(model.candidates) { candidate in
                        Button {
                            model.selected = candidate
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Phone \(candidate.peer.short)").monospaced().foregroundStyle(.primary)
                                    Text(candidate.link).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.selected == candidate { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                } header: {
                    Text("Phones nearby")
                } footer: {
                    Text("This phone is \(model.localPeer.short). The other phone should list that number.")
                }
                Section {
                    TextField("Name", text: $model.nickname)
                        .textContentType(.name)
                        .submitLabel(.done)
                    Button("Pair") { Task { await model.start() } }
                        .disabled(!model.canStart)
                } header: {
                    Text("What do you call them?")
                } footer: {
                    Text(model.notice ?? "Only you see this name. It never leaves your phone.")
                }
            case .starting:
                Section { ProgressView("Waiting for the other phone...") }
            case .comparing(let code):
                compare(code)
            case .confirming:
                Section { ProgressView("Waiting for the other phone...") }
            case .paired(let peer):
                Section {
                    Label("Paired with \(peer.nickname)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Done", action: onDone)
                }
            case .failed(let failure):
                Section {
                    Label(PairingModel.message(for: failure), systemImage: failure == .codeMismatch ? "exclamationmark.shield" : "xmark.circle")
                        .foregroundStyle(failure == .codeMismatch ? .red : .primary)
                    Button("Try again") {
                        model.reset()
                        Task { await model.start() }
                    }
                }
            }
        }
        .navigationTitle("Pair a friend")
        // Keeps the nearby list current while the owner is choosing.
        .task {
            while !Task.isCancelled {
                if model.phase == .idle { await model.refreshCandidates() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // Covers a swipe down on the sheet as well as Close.
        .onDisappear { Task { await model.end() } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    Task { await model.cancel() }
                    onDone()
                }
            }
        }
    }

    @ViewBuilder private func compare(_ code: String) -> some View {
        Section {
            Text(code)
                .font(.system(size: 44, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical)
                .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
        } header: {
            Text("Does the other phone show this code?")
        } footer: {
            Text("If the codes differ, someone else may be trying to connect. Tap \"Codes are different\".")
        }
        Section {
            Button("Codes match") { Task { await model.confirm(codesMatch: true) } }
            Button("Codes are different", role: .destructive) { Task { await model.confirm(codesMatch: false) } }
            Button("Cancel") { Task { await model.cancel() } }
        }
    }
}

// MARK: - Lane E2 slot

/// Lane E2's DeviceDiscoveryUI views: one phone lets the other find it, the
/// other finds it, and the system pairs them. Hidden where Wi-Fi Aware cannot
/// run. OS pairing only links the devices; Starling's own code check (lane
/// E1's ceremony, started by "Start pairing") pins the friend's key, and
/// until E1 is wired Debug builds run it with a test friend.
struct DeviceDiscoverySlot: View {
    /// The device the owner picked in the system picker; the pairing model
    /// turns it into the PeerID to pair with (lane E2, PR #38).
    var onPicked: (WiFiAwarePairedDevice) -> Void = { _ in }

    var body: some View {
        if WiFiAwareSupport.isSupported {
            WiFiAwarePairingButtons(onPicked: onPicked)
        } else {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nearby phones")
                    Text("This iPhone can't pair over Wi-Fi Aware (it needs an iPhone 12 or later, and not the Simulator). This build pairs with a test friend.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "antenna.radiowaves.left.and.right")
            }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { PairingView(model: PreviewSupport.app().makePairing()!, onDone: {}) }
}
#endif
