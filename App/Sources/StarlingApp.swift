import StarlingFeatures
import SwiftUI
import UIKit

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
            Group {
                #if DEBUG
                RootView(app: app, developer: { DeveloperView(app: app, harness: harness) })
                    .task { await DownSelfTest.runIfRequested(app: app, harness: harness) }
                #else
                RootView(app: app, developer: { DeveloperView(app: app) })
                #endif
            }
            // Lane F requires shutdown() on teardown (docs/requests/F.md).
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                Task { await app.shutdown() }
            }
        }
    }
}
