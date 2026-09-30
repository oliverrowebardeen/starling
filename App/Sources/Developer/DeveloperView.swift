import StarlingCore
import StarlingFeatures
import SwiftUI

/// Phase 0 tools and build information.
struct DeveloperView: View {
    let app: AppModel
    #if DEBUG
    let harness: DebugHarness
    #endif
    @AppStorage(RootView<EmptyView>.onboardingKey) private var onboardingFinished = false

    var body: some View {
        List {
            Section {
                NavigationLink("Model Bench", destination: ModelBenchView())
                #if DEBUG
                NavigationLink("Nearby", destination: NearbyView())
                #endif
            } header: {
                Text("Phase 0 spike")
            } footer: {
                #if DEBUG
                Text("Nearby links are not encrypted, so don't send anything personal. Nearby is left out of Release builds.")
                #endif
            }

            Section("Build") {
                LabeledContent("Services", value: buildKind)
                Button("Show onboarding again") { onboardingFinished = false }
            }
        }
        .navigationTitle("Developer")
    }

    private var buildKind: String {
        #if DEBUG
        "Debug (fakes for unmerged lanes)"
        #else
        "Release (no fakes)"
        #endif
    }
}
