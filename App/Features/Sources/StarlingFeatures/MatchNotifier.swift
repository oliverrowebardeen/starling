import Foundation
import StarlingCore

/// The content of a match notification. It can only be built from a
/// `DownMatch`, so nothing but a mutual match can produce a notification
/// (match-before-notify, brief 2.6).
public struct MatchNotice: Hashable, Sendable {
    /// One per friend: a newer match with the same friend replaces the older
    /// notification instead of stacking up (the Down to Lunch spam problem).
    public let id: String
    public let title: String
    public let body: String

    public init(match: DownMatch, friendName: String, formatter: ValueFormatter) {
        id = "down-match-\(match.peer.hex)"
        title = match.bothDown ? "You and \(friendName) are both down" : "You and \(friendName) are both interested"
        let lines = formatter.terms(match.terms).map { "\($0.title): \($0.detail ?? "")" }
        body = lines.isEmpty ? "Open Starling to see the plan." : lines.joined(separator: "\n")
    }
}

/// Posts local notifications. The app implements it with UserNotifications.
public protocol MatchNotifier: Sendable {
    /// Asks the owner for permission. Returns whether alerts are allowed.
    func requestAuthorization() async -> Bool
    func post(_ notice: MatchNotice) async
}
