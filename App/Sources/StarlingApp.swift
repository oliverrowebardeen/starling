import SwiftUI

@main
struct StarlingApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}

struct HomeView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink("Nearby", destination: NearbyView())
                    NavigationLink("Model Bench", destination: ModelBenchView())
                } header: {
                    Text("Phase 0 spike")
                } footer: {
                    Text("Development build. Links are not encrypted yet, so don't send anything personal.")
                }

                Section("Coming in Phase 1") {
                    Label("Down?", systemImage: "hand.wave")
                    Label("Pair a friend", systemImage: "person.2")
                    Label("Your rules", systemImage: "list.bullet.rectangle")
                }
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Starling")
        }
    }
}
