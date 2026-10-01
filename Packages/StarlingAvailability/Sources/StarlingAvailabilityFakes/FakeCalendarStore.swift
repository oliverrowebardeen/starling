import Foundation
import StarlingAvailability
import Synchronization

/// A calendar event as the owner sees it, with everything Starling must not
/// share: title, place, notes, and people. Tests fill these with marker
/// strings and check that none reaches the wire, a prompt, or an event.
public struct FakeCalendarEvent: Hashable, Sendable {
    public var title: String
    public var location: String?
    public var notes: String?
    public var attendees: [String]
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var availability: CalendarEventAvailability
    public var isCancelled: Bool

    public init(
        title: String, location: String? = nil, notes: String? = nil, attendees: [String] = [],
        start: Date, end: Date, isAllDay: Bool = false, availability: CalendarEventAvailability = .busy, isCancelled: Bool = false
    ) {
        self.title = title
        self.location = location
        self.notes = notes
        self.attendees = attendees
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.availability = availability
        self.isCancelled = isCancelled
    }

    /// Every detail string, for leak checks.
    public var details: [String] { [title] + [location, notes].compactMap { $0 } + attendees }
}

/// A `CalendarStore` with scripted events and permission, behaving like
/// EventKit: reading needs full access, and the system alert changes the
/// status only from not determined or write-only.
public final class FakeCalendarStore: CalendarStore {
    private struct State {
        var status: CalendarAccessStatus
        var grantOnRequest: Bool
        var events: [FakeCalendarEvent]
        var requests = 0
        var reads = 0
        var failReads = false
    }

    private let state: Mutex<State>

    /// - Parameter grantOnRequest: What the owner taps on the system alert:
    ///   Allow (true) or Don't Allow (false).
    public init(status: CalendarAccessStatus = .fullAccess, grantOnRequest: Bool = true, events: [FakeCalendarEvent] = []) {
        state = Mutex(State(status: status, grantOnRequest: grantOnRequest, events: events))
    }

    /// Times the system alert was asked for.
    public var requestCount: Int { state.withLock(\.requests) }
    /// Times events were read.
    public var readCount: Int { state.withLock(\.reads) }
    public var events: [FakeCalendarEvent] { state.withLock(\.events) }

    public func setStatus(_ status: CalendarAccessStatus) { state.withLock { $0.status = status } }
    public func setEvents(_ events: [FakeCalendarEvent]) { state.withLock { $0.events = events } }
    /// Makes every later read throw, as a corrupt or unavailable store would.
    public func failReads(_ fail: Bool) { state.withLock { $0.failReads = fail } }

    public func accessStatus() -> CalendarAccessStatus { state.withLock(\.status) }

    public func requestFullAccess() async throws -> Bool {
        state.withLock { state in
            state.requests += 1
            if state.status.canAsk { state.status = state.grantOnRequest ? .fullAccess : .denied }
            return state.status == .fullAccess
        }
    }

    public func blocks(from start: Date, to end: Date) async throws -> [BusyBlock] {
        try state.withLock { state in
            guard state.status.canRead else { throw CalendarStoreError.notAuthorized }
            guard !state.failReads else { throw CocoaError(.fileReadUnknown) }
            state.reads += 1
            return state.events
                .filter { !$0.isCancelled && $0.start < end && $0.end > start }
                .map { BusyBlock(start: $0.start, end: $0.end, isAllDay: $0.isAllDay, availability: $0.availability) }
        }
    }
}
