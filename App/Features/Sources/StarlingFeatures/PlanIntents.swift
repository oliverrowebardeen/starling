import AppIntents
import Foundation

/// Reads the next plan for Siri and Shortcuts. The app registers the live
/// one with `AppDependencyManager` at launch; tests register their own.
public struct PlanReader: Sendable {
    public let nextPlan: @Sendable () async -> String

    public init(nextPlan: @escaping @Sendable () async -> String) {
        self.nextPlan = nextPlan
    }
}

/// "What's my next plan?" (ADR 0018 decision 4, ADR 0204). The answer names
/// friends, a time, and a place, so it runs only on an unlocked phone: the
/// default policy, `alwaysAllowed`, would read it from a locked one (review
/// of PR #54, finding 1).
public struct NextPlanIntent: AppIntent {
    public static let title: LocalizedStringResource = "What's my next plan?"
    public static let description = IntentDescription("Says your next plan with friends, from Starling on this iPhone.")
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Dependency private var plans: PlanReader

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await plans.nextPlan()))
    }
}

public enum StarlingIntents {
    /// Every intent that reads plans or friends' names. Each must require
    /// the phone to be unlocked; a test checks the whole list.
    public static let readingPersonalData: [any AppIntent.Type] = [NextPlanIntent.self]
}

/// Makes this package's intents available to the app (`AppIntentsPackage`).
public struct StarlingFeaturesIntents: AppIntentsPackage {}
