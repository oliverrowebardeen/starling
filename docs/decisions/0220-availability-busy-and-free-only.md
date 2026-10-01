# ADR 0220: Availability reads busy and free only, behind one seam

- Status: Proposed
- Date: 2026-10-01
- Owner: P15-C, Find a time

## Context

Brief 2.3 and 2.6.2 ask for availability from pluggable sources: EventKit free and busy, stated intent, and one quick question to the owner when the agent has nothing. Calendar and non-calendar agents must interoperate. ADR 0013 adds three rules: the calendar permission is asked only from Starling's one-button sheet when the owner starts Find a time; a denial falls back to asking the owner; and event titles, locations, and attendees never leave the device or enter a prompt.

Core v2 defines `AvailabilitySource` (`known(free:)`, `unknown`, `needsOwner`) and nothing that touches EventKit. Verified against Apple's documentation on 2026-10-01:

- "Your app can't request read-only access to either events or reminders. To read events or reminders from the event store, your app needs full access." The request is `requestFullAccessToEvents(completion:)` (iOS 17, macOS 14), and the Info.plist key is `NSCalendarsFullAccessUsageDescription` (iOS 17).
- "If your app has never requested access, or only has write-only access to events, you must request full access to events before attempting to fetch them." So write-only can still be upgraded by asking.
- `EKAuthorizationStatus` has `notDetermined`, `restricted`, `denied`, `fullAccess`, `writeOnly`, and the deprecated `authorized`. In the iOS 27 SDK header, `authorized` has the same raw value as `fullAccess`.
- `EKEvent.availability` is `busy`, `free`, `tentative`, `unavailable`, or `notSupported` when the event's calendar has no availability setting.
- `predicateForEvents(withStart:end:calendars:)` matches at most four years; `events(matching:)` is synchronous.

## Decision

1. **One seam, one type across it.** `CalendarStore` is the only way Starling reads a calendar. It returns `BusyBlock`s: start, end, all-day, and availability. `BusyBlock` has no field for a title, place, note, URL, or person, and a test pins its stored properties, so a new field fails the build's tests. `EventKitCalendarStore` turns each `EKEvent` into a `BusyBlock` in one initializer that reads nothing else, except the owner's own participation status, which it reduces to "declined or not".
2. **What takes time.**
   - A timed event takes time unless it is marked free. Tentative, unavailable, and calendars without availability take time.
   - An all-day event takes time only when it is explicitly busy or unavailable. Birthdays, holidays, and "working from home" leave the day open.
   - Cancelled events and invitations the owner declined take no time.
   - Busy time widens to whole minutes, so a block never leaves a sliver of false free time.
3. **Only the sheet asks.** `CalendarAccess.request()` is the one caller of `requestFullAccess()`, for the sheet's "Continue". `shouldShowSheet` is true only when the system alert can still appear (`notDetermined` or `writeOnly`); after a denial the skill asks the owner instead of showing a sheet that leads nowhere. Sources and skill services read the status and never ask, so a friend's request can never raise the system alert (ARCHITECTURE rule 8).
4. **The owner's switch.** `CalendarUse` (`useMyCalendar`, `justAskMe`) is You › Skills' choice for Find a time (ADR 0013, decision 3). With "Just ask me" the calendar is not read even when access is granted.
5. **Sources in order.** `OwnerAvailability.standard` tries the calendar, then stated intent, then the owner. A calendar read error counts as "does not know", so a broken calendar falls back to asking, never to a guess. Stated intent is free time the owner already said ("free tonight 7 to 11"); outside it the source does not assume the owner is free.
6. **Candidates in the owner's time zone.** `CandidateGrid` builds slots of one length on a grid inside a daily window (default 9 to 9) and thins long ranges evenly, so "next week" offers every day, not only Monday.

## Consequences

- The privacy claim "event details stay on your iPhone" holds by construction at the seam, and the Find a time tests check it end to end with marker strings planted in fake events.
- The macOS test host never touches the real event store: tests use `StarlingAvailabilityFakes.FakeCalendarStore`, which behaves like EventKit (reading needs full access; the alert changes only `notDetermined` and `writeOnly`). The EventKit adapter itself is checked on a device (checklist).
- Declined invitations are read through `EKEvent.attendees`. The list stays inside the adapter, reduced to one boolean.
- The fakes are a separate product, `StarlingAvailabilityFakes`. The release check in ADR 0140 looks for `StarlingFakes` symbols only; extending it is requested in `docs/requests/P15-C.md`.

## Sources

- EventKit, Accessing the event store: https://developer.apple.com/documentation/eventkit/accessing-the-event-store
- `requestFullAccessToEvents(completion:)`: https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoevents(completion:)
- `EKAuthorizationStatus`: https://developer.apple.com/documentation/eventkit/ekauthorizationstatus
- `EKEvent.availability` and `EKEventAvailability`: https://developer.apple.com/documentation/eventkit/ekevent/availability
- `predicateForEvents(withStart:end:calendars:)`: https://developer.apple.com/documentation/eventkit/ekeventstore/predicateforevents(withstart:end:calendars:)
- `NSCalendarsFullAccessUsageDescription`: https://developer.apple.com/documentation/bundleresources/information-property-list/nscalendarsfullaccessusagedescription
- iOS 27.0 SDK, `EventKit.framework/Headers/EKTypes.h` and `EKEventStore.h` (Xcode 27.0, 27A266a)
- ADR 0013; brief sections 2.3 and 2.6.2
