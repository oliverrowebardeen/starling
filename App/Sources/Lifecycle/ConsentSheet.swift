import StarlingCore
import StarlingDesign
import StarlingFeatures
import SwiftUI

/// Shows exactly what will leave the phone and asks the owner (brief 3.7,
/// App Review guideline 5.1.2(i)). It cannot be swiped away: the owner
/// answers Send or Don't send, and no answer times out as a decline. A
/// roster is one row per person with their pair symbol (issue #46).
struct ConsentSheet: View {
    let request: ConsentCoordinator.Request
    let answer: (ConsentOutcome) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(request.items.enumerated()), id: \.offset) { index, item in
                        let roster = index < request.rosters.count ? request.rosters[index] : []
                        if roster.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                if let detail = item.detail {
                                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.title)
                                ForEach(roster) { person in RosterRowView(row: person) }
                            }
                        }
                    }
                } header: {
                    Text("What leaves your phone")
                }

                Section {
                    Text(request.recipientModel ?? "Their agent hasn't said where its model runs")
                } header: {
                    Text("\(request.recipientName)'s agent")
                }

                // Lane G's notices: locality is self-declared, what the
                // matching step reveals, and the protocol metadata sent too.
                Section {
                    ForEach(request.notices, id: \.self) { Text($0).font(.footnote) }
                }
            }
            .navigationTitle("Send to \(request.recipientName)?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if request.recipientIsFriend {
                    ToolbarItem(placement: .topBarLeading) {
                        PairSymbol(seed: request.disclosure.recipient.bytes).frame(width: 28, height: 28)
                    }
                }
            }
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

/// One person in a roster: their pair symbol (friends only) and the
/// `RosterLabels` words for them.
struct RosterRowView: View {
    let row: RosterRow

    var body: some View {
        HStack(spacing: 10) {
            if row.isKnown {
                PairSymbol(seed: row.peer.bytes).frame(width: 24, height: 24)
            } else {
                Image(systemName: "questionmark.circle")
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            Text(row.label)
                .font(.subheadline)
                .foregroundStyle(row.isKnown ? .primary : .secondary)
        }
    }
}

#if DEBUG
#Preview {
    @Previewable @State var app = PreviewSupport.app()
    Color.clear
        .sheet(item: Binding(get: { app.consent.current }, set: { _ in })) { request in
            ConsentSheet(request: request) { app.consent.answer($0, to: request.id) }
        }
        .task {
            let friends = (try? await app.services.peers?.all()) ?? []
            if let friend = friends.first, let disclosure = try? DebugHarness.sampleDisclosure(to: friend.id, start: Date(), roster: friends.map(\.id)) {
                _ = await app.consent.requestConsent(for: disclosure)
            }
        }
}
#endif
