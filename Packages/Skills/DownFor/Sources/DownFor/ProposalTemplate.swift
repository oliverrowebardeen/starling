import Foundation
import StarlingCore

/// The proposal sentence without the model (ADR 0016): the same sentence
/// `SkillModel.proposalText` writes, from the same typed facts. Shown only
/// on this phone. Names are the owner's own nicknames for friends.
public enum ProposalTemplate {
    /// "You, Maya and Jake are all down for boba. Tonight at 8:30 PM?"
    ///
    /// - Parameter now: Decides "tonight", "tomorrow", or a weekday.
    public static func sentence(_ facts: ProposalFacts, now: Date = Date()) -> String {
        let names = facts.friendNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let who: String = switch names.count {
        case 0: "You're"
        case 1: "You and \(names[0]) are both"
        default: "You, \(names.dropLast().joined(separator: ", ")) and \(names.last!) are all"
        }
        // Down never appears without an activity (ADR 0017).
        let opening = facts.activity.map { "\(who) down for \($0.value)." } ?? "\(who) free."
        var details: [String] = []
        if let place = facts.place { details.append(place.rawValue) }
        if let time = facts.time { details.append(when(time.start, now: now, timeZone: facts.timeZone)) }
        guard !details.isEmpty else { return opening }
        let question = details.joined(separator: " ")
        return "\(opening) \(question.prefix(1).uppercased() + question.dropFirst())?"
    }

    /// "tonight at 8:30 PM", "tomorrow at 9 AM", "Saturday at 2 PM".
    static func when(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let clock = (hour % 12 == 0 ? "12" : "\(hour % 12)") + (minute == 0 ? "" : String(format: ":%02d", minute)) + (hour < 12 ? " AM" : " PM")
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let day: String = switch days {
        case 0: hour >= 17 ? "tonight" : "today"
        case 1: "tomorrow"
        default: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][calendar.component(.weekday, from: date) - 1]
        }
        return "\(day) at \(clock)"
    }
}
