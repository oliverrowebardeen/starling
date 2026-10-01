import Foundation
import Observation
import StarlingCore

public enum PermissionStatus: Hashable, Sendable {
    case notDetermined
    case granted
    /// Photos with limited library access: only the photos the owner picked.
    case limited
    case denied
}

/// One system permission's status and request. Lanes C (calendar), D
/// (location), and E (photos) provide the real ones with their skills; the
/// app asks only through `PermissionGate`, never at launch (ADR 0013).
public protocol PermissionAccess: Sendable {
    var permission: SystemPermission { get }
    func status() async -> PermissionStatus
    /// Shows the system alert. Called only after Starling's own sheet.
    func request() async -> PermissionStatus
}

/// Starling's sheet before a system alert (ADR 0013 decision 3): what the
/// agent reads, what never leaves the phone, and what friends see, with
/// one "Continue" button and no way to cancel. The system alert that
/// follows is where the owner says no.
public struct PermissionExplanation: Hashable, Sendable, Identifiable {
    public var id: SystemPermission { permission }
    public let permission: SystemPermission
    public let title: String
    public let body: String
    public let rows: [DisplayLine]
    public let footnote: String
    /// Shown when the owner says no in the system alert.
    public let fallback: String

    public static let continueLabel = "Continue"

    /// - Parameters:
    ///   - friends: The names of the friends the request goes to, the
    ///     owner's own nicknames, so the sheet can say who sees what.
    ///   - role: Whether the owner is starting the skill or answering a
    ///     friend. What the friend sees differs (ADR 0013 amendment 6).
    public static func make(_ permission: SystemPermission, skill: SkillDescriptor, friends: [String], role: InteractionRole = .initiator) -> PermissionExplanation {
        let who = Self.names(friends)
        let sees = friends.count == 1 ? "\(who) sees" : "\(who) see"
        switch permission {
        case .calendarFullAccess:
            return PermissionExplanation(
                permission: permission,
                title: "\(skill.wording.name) works best with your calendar",
                body: "Your agent checks when you're busy, right here on your iPhone, so \(friends.count == 1 ? "\(who)'s agent" : "your friends' agents") never \(friends.count == 1 ? "has" : "have") to ask you.",
                rows: [
                    DisplayLine(title: "Your agent reads", detail: "When you're busy or free"),
                    DisplayLine(title: "Never leaves your phone", detail: "Event names, places, people"),
                    // Without private set intersection, the one who starts
                    // names some free times first, so "both free" is true
                    // only for the friend who answers (ADR 0013 amendment 6).
                    DisplayLine(title: sees, detail: role == .initiator ? "Only a few times you're free" : "Only times you're both free"),
                ],
                footnote: "Change this anytime in You › Skills.",
                fallback: "No problem, your agent will ask you instead."
            )
        case .locationWhenInUse:
            return PermissionExplanation(
                permission: permission,
                title: "\(skill.wording.name) can suggest places near you",
                body: "Your agent looks for places around where you are, right here on your iPhone, only while you're using Starling.",
                rows: [
                    DisplayLine(title: "Your agent reads", detail: "Where you are while you use it"),
                    DisplayLine(title: "Never leaves your phone", detail: "Your exact location"),
                    DisplayLine(title: sees, detail: "Only the places you might agree on"),
                ],
                footnote: "Change this anytime in You › Skills.",
                fallback: "No problem, type an area or pick a place instead."
            )
        case .photoLibrary:
            return PermissionExplanation(
                permission: permission,
                title: "\(skill.wording.name) shares only the photos you choose",
                body: "Your agent finds photos from the plan's time on your iPhone, and you approve each one before it's shared.",
                rows: [
                    DisplayLine(title: "Your agent reads", detail: "Photos from the plan's time"),
                    DisplayLine(title: "Never leaves your phone", detail: "Every photo you don't approve"),
                    DisplayLine(title: sees, detail: "Only the photos you approve"),
                ],
                footnote: "Change this anytime in You › Skills.",
                fallback: "No problem, \(skill.wording.name) stays off."
            )
        }
    }

    /// "Maya", "Maya and Jake", "Maya, Jake and Leo", or "Your friends".
    public static func names(_ friends: [String]) -> String {
        switch friends.count {
        case 0: "Your friends"
        case 1: friends[0]
        default: friends.dropLast().joined(separator: ", ") + " and " + friends.last!
        }
    }
}

/// Asks for a skill's system permissions just in time (ADR 0013): the
/// first time the owner uses the feature, Starling's sheet explains, the
/// owner taps Continue, and only then does the system alert appear. A
/// denial switches the skill to its no-permission path ("Just ask me")
/// and never blocks it.
@MainActor
@Observable
public final class PermissionGate {
    public enum Outcome: Hashable, Sendable {
        case granted
        /// Limited photo access: only the photos the owner picked.
        case limited
        /// The owner said no, now or before, or chose "Just ask me" in You.
        /// The skill runs on its no-permission path; `fallback` says how.
        case askInstead(fallback: String?)
        /// No access API is in this build (the skill's lane has not merged).
        /// The skill runs on its no-permission path.
        case unavailable
    }

    /// The sheet the app is showing, if any.
    public private(set) var pending: PermissionExplanation?
    private var waiting: CheckedContinuation<Void, Never>?
    private let access: [SystemPermission: any PermissionAccess]

    public init(access: [any PermissionAccess]) {
        var byPermission: [SystemPermission: any PermissionAccess] = [:]
        for item in access { byPermission[item.permission] = item }
        self.access = byPermission
    }

    public func status(of permission: SystemPermission) async -> PermissionStatus? {
        await access[permission]?.status()
    }

    /// Makes sure `permission` is settled for `skill`, asking at most once.
    public func prepare(_ permission: SystemPermission, for skill: SkillDescriptor, friends: [String], role: InteractionRole = .initiator, settings: SettingsModel) async -> Outcome {
        if settings.asksInstead(skill.id) { return .askInstead(fallback: nil) }
        guard let access = access[permission] else { return .unavailable }
        switch await access.status() {
        case .granted: return .granted
        case .limited: return .limited
        case .denied: return .askInstead(fallback: nil)
        case .notDetermined: break
        }
        let explanation = PermissionExplanation.make(permission, skill: skill, friends: friends, role: role)
        // A second request while a sheet is up waits its turn.
        while waiting != nil { try? await Task.sleep(for: .milliseconds(50)) }
        await withCheckedContinuation { continuation in
            waiting = continuation
            pending = explanation
        }
        await settings.markExplained(permission)
        switch await access.request() {
        case .granted: return .granted
        case .limited: return .limited
        case .denied, .notDetermined:
            await settings.setAskInstead(skill.id, true)
            return .askInstead(fallback: explanation.fallback)
        }
    }

    /// The owner tapped Continue on the sheet.
    public func proceed() {
        let continuation = waiting
        waiting = nil
        pending = nil
        continuation?.resume()
    }
}
