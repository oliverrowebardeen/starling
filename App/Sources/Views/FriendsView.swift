import StarlingCore
import StarlingFeatures
import SwiftUI

/// Paired friends, backed by the paired-peer store.
struct FriendsView: View {
    let model: FriendsModel
    let makePairing: () -> PairingModel?

    @State private var pairing: PairingSheet?
    @State private var renaming: PairedPeer?
    @State private var newName = ""
    @State private var removing: PairedPeer?

    var body: some View {
        List {
            if let notice = model.notice { NoticeSection(text: notice) }
            ForEach(model.friends, id: \.id) { friend in
                HStack {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(model.isReachable(friend.id) ? .green : .secondary)
                        .accessibilityLabel(model.isReachable(friend.id) ? "Reachable" : "Not reachable")
                    VStack(alignment: .leading) {
                        Text(friend.nickname)
                        Text("Paired \(friend.pairedAt.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
                .onTapGesture {
                    guard model.canRename else { return }
                    newName = friend.nickname
                    renaming = friend
                }
                .swipeActions {
                    Button("Unpair", role: .destructive) { removing = friend }
                }
            }
        }
        .overlay {
            if model.isLoaded && model.friends.isEmpty {
                ContentUnavailableView {
                    Label("No friends yet", systemImage: "person.2")
                } description: {
                    Text("Pair in person: you both tap Pair and check the codes match.")
                } actions: {
                    Button("Pair a friend") { pairing = PairingSheet(makePairing()) }
                }
            }
        }
        .navigationTitle("Friends")
        .toolbar {
            Button("Pair", systemImage: "plus") { pairing = PairingSheet(makePairing()) }
        }
        .refreshable { await model.load() }
        .sheet(item: $pairing, onDismiss: { Task { await model.load() } }) { sheet in
            NavigationStack {
                PairingView(model: sheet.model) { pairing = nil }
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let friend = renaming { Task { _ = await model.rename(friend.id, to: newName) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only you see this name.")
        }
        .confirmationDialog(
            "Unpair \(removing?.nickname ?? "")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) {
                if let friend = removing { Task { await model.remove(friend.id) } }
            }
        } message: {
            Text("To pair again, you'll need to be together.")
        }
    }
}

/// One pairing sheet, with a fresh ceremony each time it opens.
private struct PairingSheet: Identifiable {
    let id = UUID()
    let model: PairingModel

    init?(_ model: PairingModel?) {
        guard let model else { return nil }
        self.model = model
    }
}

#if DEBUG
#Preview {
    @Previewable @State var app = PreviewSupport.app()
    NavigationStack { FriendsView(model: app.friends!, makePairing: app.makePairing) }
        .task { await app.start() }
}
#endif
