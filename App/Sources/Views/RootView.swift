import StarlingChaining
import StarlingCore
import StarlingFeatures
import SwiftUI

/// Home, Friends, and You in the tab bar, with New as the prominent tab
/// (ADR 0015): a navigation destination whose screen is the composer. The
/// consent sheet, Starling's pre-permission sheet, and It's a plan appear
/// over any screen. Nothing is asked at launch (ADR 0013).
struct RootView<Developer: View>: View {
    let app: AppModel
    @ViewBuilder let developer: () -> Developer
    @State private var tab = AppTab.home
    @State private var previousTab = AppTab.home
    @Environment(\.scenePhase) private var scenePhase

    enum AppTab: Hashable {
        case home, friends, you, new
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                NavigationStack {
                    HomeView(app: app, startNew: { tab = .new }, continueWith: continuePlan)
                }
            }
            Tab("Friends", systemImage: "person.2", value: AppTab.friends) {
                NavigationStack { FriendsView(app: app) }
            }
            Tab("You", systemImage: "person.crop.circle", value: AppTab.you) {
                NavigationStack { YouView(app: app, developer: developer) }
            }
            Tab("New", systemImage: "plus", value: AppTab.new, role: .prominent) {
                NavigationStack {
                    NewView(app: app, composer: app.composer, done: { tab = .home }, cancel: { tab = previousTab })
                }
            }
        }
        .onChange(of: tab) { old, new in
            if new == .new, old != .new { previousTab = old }
        }
        .task {
            await app.start()
            #if DEBUG
            // Debug only: `-starlingComposeText "boba tonight"` opens New with
            // those words, to look at the chips without typing.
            if let text = UserDefaults.standard.string(forKey: "starlingComposeText") {
                app.composer.text = text
                tab = .new
            }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { app.foreground() }
        }
        // The consent sheet can appear over any screen. Only the owner's
        // answer dismisses it (ConsentSheet), so the setter never declines.
        .sheet(item: Binding(get: { app.consent.current }, set: { _ in })) { request in
            ConsentSheet(request: request) { app.consent.answer($0, to: request.id) }
        }
        .sheet(item: Binding(get: { app.permissions.pending }, set: { _ in })) { explanation in
            PrePermissionSheet(explanation: explanation) { app.permissions.proceed() }
        }
        .sheet(item: Binding(get: { app.celebrating.flatMap(app.lifecycle.interaction) }, set: { if $0 == nil { app.celebrating = nil } })) { root in
            ItsAPlanView(app: app, root: root) { next in continuePlan(root, next) }
        }
        .alert("Want a heads-up when friends are up for it?", isPresented: Binding(
            get: { app.composer.offerNotifications },
            set: { if !$0 { app.composer.offerNotifications = false } }
        )) {
            Button("Turn on") { Task { await app.answerNotifications(true) } }
            Button("Not now", role: .cancel) { Task { await app.answerNotifications(false) } }
        } message: {
            Text("Starling tells you only when there's a plan or something needs you.")
        }
    }

    /// Keep it going: New opens on the chained step (ADR 0012).
    private func continuePlan(_ root: Interaction, _ next: ChainSuggestion) {
        app.composer.continuePlan(root, with: next)
        tab = .new
    }
}

#if DEBUG
#Preview {
    @Previewable @State var app = PreviewSupport.app()
    RootView(app: app, developer: { Text("Developer") })
}
#endif
