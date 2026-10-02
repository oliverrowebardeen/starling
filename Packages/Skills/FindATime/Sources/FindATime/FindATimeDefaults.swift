import Foundation
import StarlingCore

/// What Find a time searches when the owner names no days (device test 2,
/// issue #95): the next 7 days, in the activity's usual hours when it is a
/// meal ("dinner" is the evening), never just tonight. Compose shows it as
/// the time chip and resets to it; the service uses it for a request with
/// no time of its own.
public enum FindATimeDefaults {
    /// Usual local hours for meal words, in minutes after midnight. Whole
    /// hours, so hourly candidates start on the hour.
    public static let breakfast = (from: 7 * 60, to: 10 * 60)
    public static let brunch = (from: 10 * 60, to: 13 * 60)
    public static let lunch = (from: 11 * 60, to: 14 * 60)
    public static let dinner = (from: 17 * 60, to: 21 * 60)

    /// Days searched when none are named.
    public static let days = 7

    /// The meal hours an activity names ("team dinner", "brunch"), or nil
    /// for anything else, which leaves the skill's default hours (9 to 9).
    public static func dailyWindow(for activity: Keyword?) -> (from: Int, to: Int)? {
        guard let words = activity?.value.split(separator: " ").map(String.init) else { return nil }
        if words.contains("breakfast") { return breakfast }
        if words.contains("brunch") { return brunch }
        if words.contains("lunch") { return lunch }
        if words.contains("dinner") || words.contains("supper") { return dinner }
        return nil
    }

    /// The default time constraints: the next 7 days from `now`, plus the
    /// meal's daily window if the activity is a meal.
    public static func timeConstraints(activity: Keyword?, now: Date) throws -> [Constraint] {
        var constraints = [try Constraint(.within([TimeSlot(start: now, end: now.addingTimeInterval(TimeInterval(days) * 86_400))]))]
        if let window = dailyWindow(for: activity) {
            constraints.append(try Constraint(.dailyWindow(from: window.from, to: window.to)))
        }
        return constraints
    }
}
