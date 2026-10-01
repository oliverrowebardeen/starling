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
            #if DEBUG
            RootView(app: app, developer: { DeveloperView(app: app, harness: harness) })
            #else
            RootView(app: app, developer: { DeveloperView(app: app) })
            #endif
        }
    }
}
