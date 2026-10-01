import Foundation

// The seam between Starling and the owner's calendar. `EventKitCalendarStore`
// is the real one; `StarlingAvailabilityFakes.FakeCalendarStore` is the test
// double. The only thing that crosses this seam is `BusyBlock`: when, and
// whether the time is taken. It has no field for a title, a place, a note,
// or a person, so event details cannot leave the store by construction
// (ADR 0013, decision 5; ADR 0220).

/// Starling's view of the calendar permission, from EventKit's
/// `EKAuthorizationStatus`.
public enum CalendarAccessStatus: String, Hashable, Sendable, Codable, CaseIterable {
    /// The owner has not been asked. Starling's sheet, then the system
    /// alert, can still appear.
    case notDetermined
    /// Full access: the only level that can read events.
    case fullAccess
    /// Can add events but not read them. Reading needs full access, which
    /// the system can still be asked for.
    case writeOnly
    /// The owner chose Don't Allow. Only Settings can change it.
    case denied
    /// Parental controls or a profile block access. The owner cannot change it.
    case restricted

    /// Whether the calendar can be read now.
    public var canRead: Bool { self == .fullAccess }

    /// Whether asking would show the system alert, so Starling's one-button
    /// sheet should come first (ADR 0013, decision 3).
    public var canAsk: Bool { self == .notDetermined || self == .writeOnly }
}

/// What an event's owner set as its availability, from EventKit's
/// `EKEventAvailability`.
public enum CalendarEventAvailability: String, Hashable, Sendable, Codable, CaseIterable {
    case busy, tentative, unavailable, free
    /// The event's calendar has no availability setting.
    case notSupported
}

/// One stretch of calendar time, with nothing about what it is.
///
/// Built from an event's start, end, all-day flag, and availability. There
/// is deliberately no title, location, notes, URL, or attendee field: a test
/// checks the stored properties, so adding one fails the build's tests.
public struct BusyBlock: Hashable, Sendable {
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let availability: CalendarEventAvailability

    public init(start: Date, end: Date, isAllDay: Bool, availability: CalendarEventAvailability) {
        self.start = start
        // A malformed event (end before start) becomes empty and blocks nothing.
        self.end = max(start, end)
        self.isAllDay = isAllDay
        self.availability = availability
    }

    /// Whether the block makes the owner unavailable.
    ///
    /// - A timed event blocks unless it is marked free.
    /// - An all-day event blocks only when it is explicitly busy or
    ///   unavailable. Birthdays, holidays, and "working from home" are
    ///   all-day events that leave the day open.
    public var blocksTime: Bool {
        guard end > start else { return false }
        if isAllDay { return availability == .busy || availability == .unavailable }
        return availability != .free
    }
}

public enum CalendarStoreError: Error, Hashable, Sendable {
    /// Reading needs full access, and the store does not have it.
    case notAuthorized
}

/// Reads the owner's calendar, reduced to busy blocks.
///
/// Implementations never ask for permission on their own: only
/// `requestFullAccess()` does, and only `CalendarAccess.request()` calls it,
/// from Starling's pre-permission sheet. A source that reads availability
/// checks `accessStatus()` and falls back when it cannot read.
public protocol CalendarStore: Sendable {
    func accessStatus() -> CalendarAccessStatus
    /// Shows the system alert if the owner has not answered it. Returns
    /// whether full access is granted.
    func requestFullAccess() async throws -> Bool
    /// Blocks overlapping `[start, end)`. Throws `CalendarStoreError.notAuthorized`
    /// without full access.
    func blocks(from start: Date, to end: Date) async throws -> [BusyBlock]
}
