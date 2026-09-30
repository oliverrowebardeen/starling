import StarlingCore
import StarlingFeatures
import SwiftUI

/// Shows exactly what will leave the phone and asks the owner (brief 3.7,
/// App Review guideline 5.1.2(i)). It cannot be swiped away: the owner
/// answers Send or Don't send, and no answer times out as a decline.
struct ConsentSheet: View {
    let request: ConsentCoordinator.Request
    /// False while the PSI in use is `InsecurePSIStub`.
    let psiIsPrivate: Bool
    let answer: (ConsentOutcome) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(request.items, id: \.self) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                            if let detail = item.detail {
                                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("What leaves your phone")
                } footer: {
                    if !psiIsPrivate && request.disclosure.items.contains(where: { $0.category == .psi }) {
                        Text("This test build's matching step does not hide your free times from \(request.recipientName).")
                    }
                }

                Section {
                    Text(request.recipientModel ?? "Their agent hasn't said where its model runs")
                } header: {
                    Text("\(request.recipientName)'s agent")
                } footer: {
                    Text("Starling can't check this claim yet.")
                }
            }
            .navigationTitle("Send to \(request.recipientName)?")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button { answer(.approved) } label: {
                        Text("Send").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { answer(.declined) } label: {
                        Text("Don't send").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
        }
        .interactiveDismissDisabled()
    }
}

#if DEBUG
#Preview {
    @Previewable @State var app = PreviewSupport.app()
    Color.clear
        .sheet(item: Binding(get: { app.consent.current }, set: { _ in })) { request in
            ConsentSheet(request: request, psiIsPrivate: false) { app.consent.answer($0) }
        }
        .task {
            let friend = try? await app.services.peers?.all().first
            if let friend, let disclosure = try? DebugHarness.sampleDisclosure(to: friend.id) {
                _ = await app.consent.requestConsent(for: disclosure)
            }
        }
}
#endif
