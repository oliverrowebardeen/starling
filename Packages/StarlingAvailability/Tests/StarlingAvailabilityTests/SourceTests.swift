import EventKit
import Foundation
import StarlingAvailability
import StarlingAvailabilityFakes
import StarlingCore
import StarlingFakes
import Testing

struct CalendarAccessTests {
    @Test func sheetAppearsOnlyWhenTheSystemAlertCan() {
        for status in CalendarAccessStatus.allCases {
            let access = CalendarAccess(store: FakeCalendarStore(status: status))
            #expect(access.shouldShowSheet == (status == .notDetermined || status == .writeOnly), "\(status)")
        }
    }

    @Test func continueThenAllowGivesFullAccess() async {
        let store = FakeCalendarStore(status: .notDetermined, grantOnRequest: true)
        #expect(await CalendarAccess(store: store).request() == .fullAccess)
        #expect(store.requestCount == 1)
    }

    @Test func continueThenDontAllowGivesDenied() async {
        let store = FakeCalendarStore(status: .notDetermined, grantOnRequest: false)
        #expect(await CalendarAccess(store: store).request() == .denied)
        #expect(!CalendarAccess(store: store).shouldShowSheet)
    }

    @Test func writeOnlyCanStillAskForFullAccess() async {
        let store = FakeCalendarStore(status: .writeOnly, grantOnRequest: true)
        #expect(await CalendarAccess(store: store).request() == .fullAccess)
    }

    @Test func aDeniedOrRestrictedStatusNeverReachesTheSystem() async {
        for status in [CalendarAccessStatus.denied, .restricted, .fullAccess] {
            let store = FakeCalendarStore(status: status)
            #expect(await CalendarAccess(store: store).request() == status)
            #expect(store.requestCount == 0)
        }
    }

    @Test func purposeStringNamesTheUseAndKeepsDetailsOnThePhone() {
        #expect(CalendarAccess.usageDescriptionKey == "NSCalendarsFullAccessUsageDescription")
        #expect(CalendarAccess.purposeString.contains("busy"))
        #expect(CalendarAccess.purposeString.contains("Event details stay on your iPhone"))
        #expect(!CalendarAccess.purposeString.contains("\u{2014}"))
    }

    @Test func eventKitStatusesMap() {
        #expect(CalendarAccessStatus(EKAuthorizationStatus.notDetermined) == .notDetermined)
        #expect(CalendarAccessStatus(EKAuthorizationStatus.fullAccess) == .fullAccess)
        #expect(CalendarAccessStatus(EKAuthorizationStatus.writeOnly) == .writeOnly)
        #expect(CalendarAccessStatus(EKAuthorizationStatus.denied) == .denied)
        #expect(CalendarAccessStatus(EKAuthorizationStatus.restricted) == .restricted)
        #expect(CalendarEventAvailability(EKEventAvailability.tentative) == .tentative)
        #expect(CalendarEventAvailability(EKEventAvailability.notSupported) == .notSupported)
    }
}

struct SourceTests {
    static let meeting = FakeCalendarEvent(
        title: "Dentist", location: "12 Hidden Lane", notes: "bring forms", attendees: ["Dr. Ruiz"],
        start: T.at(10), end: T.at(11)
    )

    func query(_ from: Double, _ to: Double) throws -> AvailabilityQuery {
        try AvailabilityQuery(window: T.slot(from, to), granularityMinutes: 30)
    }

    @Test func calendarGivesFreeTimeAroundEvents() async throws {
        let store = FakeCalendarStore(events: [Self.meeting])
        let source = EventKitAvailabilitySource(store: store, use: { .useMyCalendar })
        #expect(try await source.availability(for: query(9, 12)) == .known(free: [T.slot(9, 10), T.slot(11, 12)]))
    }

    @Test func calendarDefersWhenItCannotRead() async throws {
        for status in [CalendarAccessStatus.notDetermined, .writeOnly, .denied, .restricted] {
            let store = FakeCalendarStore(status: status, events: [Self.meeting])
            let source = EventKitAvailabilitySource(store: store, use: { .useMyCalendar })
            #expect(try await source.availability(for: query(9, 12)) == .unknown)
            // A source never raises the system alert.
            #expect(store.requestCount == 0)
            #expect(store.readCount == 0)
        }
    }

    @Test func justAskMeNeverReadsTheCalendar() async throws {
        let store = FakeCalendarStore(events: [Self.meeting])
        let source = EventKitAvailabilitySource(store: store, use: { .justAskMe })
        #expect(try await source.availability(for: query(9, 12)) == .unknown)
        #expect(store.readCount == 0)
    }

    @Test func statedIntentGivesOnlyWhatWasStated() async throws {
        let source = StatedIntentAvailabilitySource(windows: { [T.slot(19, 23), T.slot(40, 41)] })
        #expect(try await source.availability(for: query(18, 22)) == .known(free: [T.slot(19, 22)]))
        #expect(try await source.availability(for: query(9, 12)) == .unknown)
    }

    @Test func askOwnerAlwaysAsks() async throws {
        let answer = try await AskOwnerAvailabilitySource(maxSuggestions: 3).availability(for: query(9, 12))
        guard case .needsOwner(let question) = answer else { Issue.record("expected a question"); return }
        #expect(question.window == T.slot(9, 12))
        #expect(question.suggestions == [T.slot(9, 9.5), T.slot(10, 10.5), T.slot(11.5, 12)])
    }

    @Test func chainTriesCalendarThenStatedThenOwner() async throws {
        let store = FakeCalendarStore(status: .denied, events: [Self.meeting])
        let chain = OwnerAvailability.standard(calendar: store, use: { .useMyCalendar }, stated: { [T.slot(9, 10)] })
        let stated = await chain.answer(for: try query(9, 12))
        #expect(stated.source == .statedIntent)
        let asked = await chain.answer(for: try query(30, 33))
        #expect(asked.source == .askOwner)

        store.setStatus(.fullAccess)
        #expect(await chain.answer(for: try query(9, 12)).source == .calendar)
    }

    @Test func aFailingCalendarFallsBackToTheOwner() async throws {
        let store = FakeCalendarStore(events: [Self.meeting])
        store.failReads(true)
        let chain = OwnerAvailability.standard(calendar: store, use: { .useMyCalendar })
        #expect(await chain.answer(for: try query(9, 12)).source == .askOwner)
    }

    @Test func resolveFiltersCandidatesByTheCalendar() async {
        let store = FakeCalendarStore(events: [Self.meeting])
        let chain = OwnerAvailability.standard(calendar: store, use: { .useMyCalendar })
        let candidates = [T.slot(9, 10), T.slot(10, 11), T.slot(11, 12)]
        #expect(await chain.resolve(candidates) == .known(acceptable: [T.slot(9, 10), T.slot(11, 12)], source: .calendar))
    }

    @Test func resolveAsksTheOwnerWithoutACalendar() async {
        let store = FakeCalendarStore(status: .denied)
        let chain = OwnerAvailability.standard(calendar: store, use: { .useMyCalendar })
        #expect(await chain.resolve([T.slot(9, 10)]) == .askOwner)
    }

    @Test func resolveSpansMoreThanFourteenDaysInChunks() async {
        let store = FakeCalendarStore(events: [FakeCalendarEvent(title: "Trip", start: T.at(24 * 15), end: T.at(24 * 15 + 2))])
        let chain = OwnerAvailability.standard(calendar: store, use: { .useMyCalendar })
        let candidates = [T.slot(1, 2), T.slot(24 * 15, 24 * 15 + 1), T.slot(24 * 15 + 3, 24 * 15 + 4)]
        #expect(await chain.resolve(candidates) == .known(acceptable: [T.slot(1, 2), T.slot(24 * 15 + 3, 24 * 15 + 4)], source: .calendar))
        #expect(store.readCount == 2)
    }

    @Test func staticSourceFromCoreFakesComposes() async throws {
        let chain = OwnerAvailability([
            StaticAvailabilitySource(kind: .calendar, answer: .unknown),
            StaticAvailabilitySource(kind: .statedIntent, answer: .known(free: [T.slot(0, 48)])),
        ])
        #expect(await chain.answer(for: try query(9, 10)).answer == .known(free: [T.slot(9, 10)]))
    }
}
