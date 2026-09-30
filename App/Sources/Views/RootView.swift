import StarlingCore
import StarlingFeatures
import SwiftUI

struct RootView<Developer: View>: View {
    static var onboardingKey: String { "onboarding.finished" }

    let app: AppModel
    @ViewBuilder let developer: () -> Developer

    var body: some View {
        tabs
            .task { await app.start() }
    }

    private var tabs: some View {
        TabView {
            Tab("Down?", systemImage: "hand.wave") {
                NavigationStack {
                    if let down = app.down {
                        DownView(model: down)
                    } else {
                        NotInBuildView(feature: "Down?", detail: "Matching with friends arrives when the negotiation lane merges.")
                            .navigationTitle("Down?")
                    }
                }
            }
            Tab("Friends", systemImage: "person.2") {
                NavigationStack {
                    if let friends = app.friends {
                        FriendsView(model: friends, makePairing: app.makePairing)
                    } else {
                        NotInBuildView(feature: "Friends", detail: "Pairing arrives when the identity and Wi-Fi Aware lanes merge.")
                            .navigationTitle("Friends")
                    }
                }
            }
            Tab("Rules", systemImage: "list.bullet.rectangle") {
                NavigationStack { RulesEditorView(model: app.rulesEditor) }
            }
            Tab("Developer", systemImage: "hammer") {
                NavigationStack { developer() }
            }
        }
    }
}

/// Says plainly that a feature is missing from this build instead of
/// running it on a fake.
struct NotInBuildView: View {
    let feature: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label("\(feature) isn't in this build yet", systemImage: "shippingbox")
        } description: {
            Text(detail)
        }
    }
}

#if DEBUG
#Preview {
    @Previewable @State var app = PreviewSupport.app()
    RootView(app: app, developer: { Text("Developer") })
        .defaultAppStorage(UserDefaults(suiteName: "preview")!)
}
#endif
