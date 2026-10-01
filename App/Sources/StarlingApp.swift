import StarlingFeatures
import SwiftUI
import UIKit

@main
struct StarlingApp: App {
    @State private var boot = Bootstrap()

    init() {
        UserNotificationsNotifier.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch boot.state {
                case .loading:
                    ProgressView("Opening Starling...")
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Starling couldn't start", systemImage: "key")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await boot.load() } }
                    }
                case .ready(let app):
                    #if DEBUG
                    RootView(app: app, developer: { DeveloperView(app: app, harness: boot.harness!) })
                        .task { await DownSelfTest.runIfRequested(app: app, harness: boot.harness!) }
                    #else
                    RootView(app: app, developer: { DeveloperView(app: app) })
                    #endif
                }
            }
            .task { await boot.load() }
            // Lane F requires shutdown() on teardown (docs/requests/F.md).
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                if case .ready(let app) = boot.state { Task { await app.shutdown() } }
            }
        }
    }
}

/// Builds the app's services before the first screen. Lane E1's identity
/// comes from the Keychain asynchronously, and the app must not run on a
/// made-up identity if it cannot be read.
@MainActor
@Observable
final class Bootstrap {
    enum State {
        case loading
        case ready(AppModel)
        case failed(String)
    }

    private(set) var state = State.loading
    #if DEBUG
    private(set) var harness: DebugHarness?
    #endif

    func load() async {
        if case .ready = state { return }
        state = .loading
        do {
            #if DEBUG
            let harness = harness ?? DebugHarness()
            self.harness = harness
            state = .ready(AppModel(services: try await harness.services()))
            #else
            state = .ready(AppModel(services: try await AppServices.release()))
            #endif
        } catch {
            state = .failed("Its keys in the Keychain couldn't be read. Unlock your iPhone and try again. (\(error))")
        }
    }
}
