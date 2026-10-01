import EventKit
import Foundation

/// The `CalendarStore` over EventKit.
///
/// Reading events needs full access; there is no read-only level ("Your app
/// can't request read-only access to either events or reminders", EventKit,
/// Accessing the event store). The app's Info.plist must carry
/// `NSCalendarsFullAccessUsageDescription` (`CalendarAccess.purposeString`),
/// or iOS denies the request without asking.
///
/// Each event is reduced to a `BusyBlock` in `BusyBlock(event:)`, which reads
/// the start, end, all-day flag, availability, status, and whether the owner
/// declined it. Nothing else about the event is read, kept, or returned.
public actor EventKitCalendarStore: CalendarStore {
    private let store = EKEventStore()

    public init() {}

    public nonisolated func accessStatus() -> CalendarAccessStatus {
        CalendarAccessStatus(EKEventStore.authorizationStatus(for: .event))
    }

    public func requestFullAccess() async throws -> Bool {
        let granted: Bool = try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
            }
        }
        // EventKit: events fetched before access was granted need a reset to
        // show data. Starling never fetches first, but a reset is harmless.
        if granted { store.reset() }
        return granted
    }

    public func blocks(from start: Date, to end: Date) async throws -> [BusyBlock] {
        guard accessStatus().canRead else { throw CalendarStoreError.notAuthorized }
        guard end > start else { return [] }
        // `nil` calendars means every calendar the owner has. EventKit caps a
        // predicate at four years; Starling asks for at most 14 days.
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).compactMap(BusyBlock.init(event:))
    }
}

extension BusyBlock {
    /// The one place an `EKEvent` becomes Starling data. Cancelled events and
    /// invitations the owner declined leave the time free and return nil.
    init?(event: EKEvent) {
        guard event.status != .canceled else { return nil }
        if event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined { return nil }
        guard let start = event.startDate, let end = event.endDate else { return nil }
        self.init(start: start, end: end, isAllDay: event.isAllDay, availability: CalendarEventAvailability(event.availability))
    }
}

extension CalendarAccessStatus {
    /// The deprecated `authorized` shares `fullAccess`'s raw value (3), so it
    /// reads as full access. An unknown future case cannot read.
    public init(_ status: EKAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .fullAccess: self = .fullAccess
        case .writeOnly: self = .writeOnly
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .denied
        }
    }
}

extension CalendarEventAvailability {
    public init(_ availability: EKEventAvailability) {
        switch availability {
        case .busy: self = .busy
        case .tentative: self = .tentative
        case .unavailable: self = .unavailable
        case .free: self = .free
        case .notSupported: self = .notSupported
        @unknown default: self = .busy
        }
    }
}
