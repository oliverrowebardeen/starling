import Foundation
import StarlingAvailability
import StarlingCore

/// What a skill service may read about the owner's choices, live from the
/// app: whether a skill is on, whether Find a time uses the calendar, and
/// the standing rules (P15-C request 2). The values come from the settings
/// and rules in memory, which change before they are saved, so a skill
/// turned off in You stops at once. Until the app has loaded them, every
/// answer is the cautious one: off, Just ask me, no rules.
@MainActor
public final class OwnerChoices {
    private weak var app: AppModel?

    public init() {}

    func attach(_ app: AppModel) { self.app = app }

    /// On in You and in this build's flags, once settings are loaded.
    public func isOn(_ skill: SkillID) -> Bool {
        guard let settings = app?.settings, settings.isLoaded else { return false }
        return settings.isOn(skill) && settings.flags.enabled.contains(skill)
    }

    /// You › Skills: "Use my calendar" unless the owner chose "Just ask me"
    /// or said Don't Allow to the system alert.
    public func calendarUse() -> CalendarUse {
        guard let settings = app?.settings, settings.isLoaded, !settings.asksInstead(.findATime) else { return .justAskMe }
        return .useMyCalendar
    }

    /// The owner's saved limits, such as "no plans before 10".
    public func standingConstraints() -> ConstraintSet {
        app?.standingRules.constraints ?? .empty
    }
}
