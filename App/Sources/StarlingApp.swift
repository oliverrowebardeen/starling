import AppIntents
import StarlingFeatures
import StarlingIdentity
import SwiftUI
import UIKit

@main
struct StarlingApp: App {
    @State private var boot = Bootstrap()

    init() {
        UserNotificationsNotifier.shared.install()
        AppDependencyManager.shared.add(dependency: PlanReader.live)
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
                        .task { await LifecycleSelfTest.runIfRequested(app: app, harness: boot.harness!) }
                    #else
                    // Release builds have no Developer section (ADR 0015).
                    RootView(app: app, developer: { EmptyView() })
                    #endif
                }
            }
            .task { await boot.load() }
            // Skill services must be shut down on teardown.
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
            harness.driver?.run()
            #else
            state = .ready(AppModel(services: try await AppServices.release()))
            #endif
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            // An unsigned build (for example a Simulator build with signing
            // turned off) gets no Keychain access at all.
            state = .failed("This build isn't signed, so it can't use the Keychain. Run it from Xcode with signing on (Sign to Run Locally in the Simulator).")
        } catch {
            state = .failed("Its keys in the Keychain couldn't be read. Unlock your iPhone and try again. (\(error))")
        }
    }
}
