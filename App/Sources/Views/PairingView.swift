import StarlingCore
import StarlingDesign
import StarlingFeatures
import StarlingWiFiAware
import SwiftUI

/// Add a friend, in person (brief 2.5 step 2, ADR 0003, ADR 0260): one of
/// you finds the other's phone, the other phone joins on its own, you both
/// check one code, and you name your friend. Every step is one centered
/// column with one main action, like AirDrop.
struct PairingView: View {
    @State var model: PairingModel
    let onDone: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        Group {
            switch model.phase {
            case .choosing:
                choosing
            case .connecting:
                Step {
                    StatusMark(state: .negotiating).frame(width: 96, height: 96).accessibilityHidden(true)
                } title: {
                    Text(connectingTitle)
                } detail: {
                    Text("Keep Starling open on both phones.")
                } actions: {
                    Button("Cancel") { Task { await model.cancel() } }
                }
            case .comparing(let code):
                compare(code)
            case .waiting:
                Step {
                    StatusMark(state: .negotiating).frame(width: 96, height: 96).accessibilityHidden(true)
                } title: {
                    Text("Waiting for the other phone")
                } detail: {
                    Text("They need to tap \"They match\" too.")
                } actions: {
                    Button("Cancel") { Task { await model.cancel() } }
                }
            case .naming(let peer):
                naming(peer)
            case .notifications(let friend):
                notifications(friend)
            case .done:
                Step {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                } title: {
                    Text("You're paired")
                } detail: {
                    Text("Make plans with them from New.")
                } actions: {
                    Button("Done", action: onDone).buttonStyle(.borderedProminent).controlSize(.large)
                }
            case .failed(let failure):
                Step {
                    Image(systemName: failure == .codeMismatch ? "exclamationmark.shield" : "xmark.circle")
                        .font(.system(size: 56))
                        .foregroundStyle(failure == .codeMismatch ? .red : .secondary)
                } title: {
                    Text(failure == .codeMismatch ? "The codes didn't match" : "Pairing didn't finish")
                } detail: {
                    Text(PairingModel.message(for: failure))
                } actions: {
                    Button("Try again") { Task { await model.tryAgain() } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
        .animation(.default, value: model.phase)
        .navigationTitle("Add a friend")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        Task { await model.cancel() }
                        onDone()
                    }
                }
            }
        }
        // Naming and the notification explanation each end with their one
        // button (ADR 0013 decision 3), so the sheet stays until then.
        .interactiveDismissDisabled(!showsClose)
        .task {
            await model.opened()
            // Keeps the nearby list current and joins a phone that asks.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        // Covers a swipe down on the sheet as well as Close.
        .onDisappear { Task { await model.end() } }
    }

    private var showsClose: Bool {
        switch model.phase {
        case .naming, .notifications, .done: false
        default: true
        }
    }

    private var otherPhone: String { model.phone?.label ?? "the other phone" }

    private var connectingTitle: String {
        if let picked = model.pickedName { return "Connecting to \(picked)" }
        return model.phone.map { "Connecting to \($0.label)" } ?? "Connecting"
    }

    // MARK: Steps

    private var choosing: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Hold your phones close").font(.title2.bold())
                    Text("One of you taps Find their phone. The other taps Let them find me.")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.top, 32)

                DeviceDiscoverySlot { device in
                    Task { await model.pickedDevice(id: device.id, name: device.name) }
                }

                if let notice = model.notice {
                    Text(notice).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }

                if !model.candidates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or pick their phone").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(model.candidates) { candidate in
                            Button {
                                Task { await model.choose(candidate) }
                            } label: {
                                HStack {
                                    Image(systemName: "iphone").foregroundStyle(.tint)
                                    Text(candidate.label).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                                }
                                .padding(12)
                                .background(.fill.tertiary, in: .rect(cornerRadius: 12))
                            }
                        }
                    }
                }

                Text("This phone shows up as \(model.localPeer.short) on theirs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
    }

    private func compare(_ code: String) -> some View {
        Step {
            Text(Self.spaced(code))
                .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
                .accessibilityLabel("Code \(code.filter(\.isNumber).map(String.init).joined(separator: " "))")
        } title: {
            Text("Check the code")
        } detail: {
            Text("Does \(otherPhone) show the same code?")
        } actions: {
            Button("They match") { Task { await model.confirm(codesMatch: true) } }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button("They're different", role: .destructive) { Task { await model.confirm(codesMatch: false) } }
        }
    }

    private func naming(_ peer: PairedPeer) -> some View {
        Step {
            PairSymbol(seed: peer.id.bytes).frame(width: 72, height: 72).accessibilityHidden(true)
        } title: {
            Text("What do you call them?")
        } detail: {
            VStack(spacing: 10) {
                TextField("Their name", text: $model.name)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .multilineTextAlignment(.center)
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .padding(12)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 12))
                    .onSubmit { Task { await model.saveName() } }
                if let warning = model.nameWarning {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                Text(model.notice ?? "Only you see this name. It never leaves your phone.")
                    .font(.footnote).foregroundStyle(model.notice == nil ? Color.secondary : Color.orange)
            }
        } actions: {
            Button("Done") { Task { await model.saveName() } }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!model.canSaveName)
        }
        .onAppear { nameFocused = true }
    }

    /// Starling's one-button explanation before iOS's notification alert
    /// (ADR 0013 decision 3): no close, no "Not now". iOS's own Don't Allow
    /// is the opt-out.
    private func notifications(_ friend: String) -> some View {
        Step {
            Image(systemName: "bell.badge.fill").font(.system(size: 56)).foregroundStyle(.tint).accessibilityHidden(true)
        } title: {
            Text("Get a heads-up when \(friend) wants to make plans")
        } detail: {
            Text("Starling tells you when a friend asks, a plan is ready, or something needs you. Nothing else.")
        } actions: {
            Button("Continue") { Task { await model.continueToNotifications() } }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    /// "482913" as "482 913", easier to read aloud.
    static func spaced(_ code: String) -> String {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return code }
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }
}

/// One pairing step: art, a title, a line, and its actions, centered.
private struct Step<Art: View, Title: View, Detail: View, Actions: View>: View {
    @ViewBuilder let art: () -> Art
    @ViewBuilder let title: () -> Title
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)
            art()
            VStack(spacing: 10) {
                title().font(.title2.bold())
                detail().foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            Spacer(minLength: 24)
            VStack(spacing: 12) { actions() }
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Lane E2 slot

/// Lane E2's DeviceDiscoveryUI views: one phone lets the other find it, the
/// other finds it, and the system pairs them. Where Wi-Fi Aware cannot run,
/// a line says so and the nearby list below does the job.
struct DeviceDiscoverySlot: View {
    /// The device the owner picked in the system picker; the pairing model
    /// turns it into the PeerID to pair with (lane E2, PR #38).
    var onPicked: (WiFiAwarePairedDevice) -> Void = { _ in }

    var body: some View {
        if WiFiAwareSupport.isSupported {
            WiFiAwarePairingButtons(onPicked: onPicked)
        } else {
            Text("This iPhone can't use Wi-Fi Aware (it needs an iPhone 12 or later, and not the Simulator). Pick the other phone below instead.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// Lane E2's DeviceDiscoveryUI views, shown only where Wi-Fi Aware runs.
/// `onPicked` receives the device the owner picked once the system paired it.
struct WiFiAwarePairingButtons: View {
    var onPicked: (WiFiAwarePairedDevice) -> Void = { _ in }

    var body: some View {
        #if canImport(DeviceDiscoveryUI) && canImport(WiFiAware) && os(iOS) && !targetEnvironment(macCatalyst)
        if WiFiAwareSupport.isSupported {
            VStack(spacing: 12) {
                WiFiAwareDevicePicker(onPaired: onPicked) {
                    Label("Find their phone", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                } fallback: {
                    Text("Pairing isn't available on this iPhone.").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                WiFiAwarePairingView {
                    Label("Let them find me", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                } fallback: {
                    Text("Pairing isn't available on this iPhone.").foregroundStyle(.secondary)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        #endif
    }
}

#if DEBUG
#Preview {
    NavigationStack { PairingView(model: PreviewSupport.app().makePairing()!, onDone: {}) }
}
#endif
