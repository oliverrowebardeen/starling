import Foundation
import Observation

/// Triggers the system's Local Network alert. iOS has no API to ask for the
/// permission or read its state; the alert appears on the first local
/// network operation (TN3179), so the app performs one on purpose.
public protocol LocalNetworkPrompter: Sendable {
    func prompt() async
}

/// First-run setup (brief 2.5): what Starling is and that this build is for
/// testing, Local Network, notifications, then the owner's rules.
@MainActor
@Observable
public final class OnboardingModel {
    public enum Step: Int, Hashable, Sendable, CaseIterable {
        case welcome, localNetwork, notifications, rules
    }

    public private(set) var step = Step.welcome
    public private(set) var isWorking = false
    public private(set) var notificationsAllowed: Bool?
    public private(set) var isFinished = false

    private let localNetwork: any LocalNetworkPrompter
    private let notifier: any MatchNotifier

    public init(localNetwork: any LocalNetworkPrompter, notifier: any MatchNotifier) {
        self.localNetwork = localNetwork
        self.notifier = notifier
    }

    /// Does the current step's action, then moves on.
    public func next() async {
        guard !isWorking, !isFinished else { return }
        isWorking = true
        defer { isWorking = false }
        switch step {
        case .welcome:
            step = .localNetwork
        case .localNetwork:
            await localNetwork.prompt()
            step = .notifications
        case .notifications:
            notificationsAllowed = await notifier.requestAuthorization()
            step = .rules
        case .rules:
            isFinished = true
        }
    }

    /// Moves on without the step's action. Only notifications and rules are
    /// optional; Local Network is how friends' phones are found at all.
    public func skip() {
        guard !isWorking else { return }
        switch step {
        case .notifications: step = .rules
        case .rules: isFinished = true
        case .welcome, .localNetwork: break
        }
    }
}
