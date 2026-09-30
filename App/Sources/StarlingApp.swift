import StarlingFeatures
import SwiftUI

@main
struct StarlingApp: App {
    @State private var app: AppModel
    #if DEBUG
    private let harness: DebugHarness
    #endif

    init() {
        UserNotificationsNotifier.shared.install()
        #if DEBUG
        let harness = DebugHarness()
        self.harness = harness
        _app = State(initialValue: AppModel(services: harness.services()))
        #else
        _app = State(initialValue: AppModel(services: .release()))
        #endif
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .task { await app.start() }
        }
    }
}

struct HomeView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    #if DEBUG
                    NavigationLink("Nearby", destination: NearbyView())
                    #endif
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
