import StarlingCore
import StarlingFeatures
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
                    DeviceDiscoverySlot()
                } footer: {
                    Text("Pairing only works with both of you together. Each phone will show a code; check they're the same.")
                }
                Section {
                    Button("Start pairing") { Task { await model.start() } }
                }
            case .starting:
                Section { ProgressView("Waiting for the other phone...") }
            case .comparing(let code):
                compare(code)
            case .confirming:
                Section { ProgressView("Confirming...") }
            case .naming:
                Section {
                    TextField("Name", text: $model.nickname)
                        .textContentType(.name)
                        .submitLabel(.done)
                        .onSubmit { Task { await model.saveNickname() } }
                    Button("Save") { Task { await model.saveNickname() } }
                } header: {
                    Text("What do you call them?")
                } footer: {
                    Text(model.notice ?? "Only you see this name. It never leaves your phone.")
                }
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

/// LANE E2 SLOT: the DeviceDiscoveryUI views for picking the other phone go
/// here once `StarlingWiFiAware` exposes them. The picked device should flow
/// into the pairing session factory (`AppServices.makePairingSession`), which
/// will then take the chosen endpoint. Until then this is a placeholder and
/// Debug builds pair with `ScriptedPairingSession`.
struct DeviceDiscoverySlot: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nearby phones")
                Text("Picking the other phone arrives with Wi-Fi Aware pairing. This build pairs with a test friend.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "antenna.radiowaves.left.and.right")
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { PairingView(model: PreviewSupport.app().makePairing()!, onDone: {}) }
}
#endif
