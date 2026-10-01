# ADR 0013: Permissions belong to skills and are requested just in time

- Status: Proposed. Decision 3 (the pre-permission sheet has one button) departs from the Find a time mockup and needs Oliver's agreement; the rest follows the Phase 1.5 prompt.
- Date: 2026-09-30
- Owner: Orchestrator

## Context

Phase 1.5 section 5 moves every system permission into the skill that needs it and asks only when the owner uses that skill. Nothing is requested at launch.

| Skill or action | Permission | If denied |
|---|---|---|
| Down for… | none | n/a |
| Add to Calendar | none (`EKEventEditViewController`) | n/a |
| Find a time | EventKit full access | "Just ask me instead" |
| Pick a place | Location When In Use | type or pick a place |
| Swap photos | Photos | the skill stays off; limited access offers only the selected photos |

Verified against primary sources (2026-09-30):

- **Calendar.** "Your app can't request read-only access to either events or reminders. To read events or reminders from the event store, your app needs full access." The request API is `requestFullAccessToEvents()` (iOS 17+), and the key is `NSCalendarsFullAccessUsageDescription`. Without that key, or with only the older `NSCalendarsUsageDescription`, iOS 17+ denies the request automatically.
- **Add to Calendar.** "Your app can use EventKitUI without requesting write-only or full calendar access" (EventKit docs). WWDC23 "What's new in privacy" says the same: "with EventKitUI, your app does not need any permission."
- **Location.** `requestWhenInUseAuthorization()` with `NSLocationWhenInUseUsageDescription`. MapKit search takes a region the app supplies, and no MapKit doc mentions a permission for it, so search near a typed area works without location. That last point is inferred, not stated by Apple.
- **Photos.** "The user doesn't need to explicitly authorize your app to select photos" with `PHPickerViewController`. Limited library access is `PHAuthorizationStatus.limited`. `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` controls the system's reselection prompt.
- **HIG, Privacy.** "Request permission only when your app clearly needs access to the data or resource… Ideally, wait to request permission until people actually use an app feature that requires access." A custom screen before the system alert is allowed "if it's essential to provide additional details". It should include only one button, labeled "Continue" or "Next" (not "Allow"), with no close or cancel option.

The Find a time mockup ("Just-in-time permission · Find a time") shows a sheet with two actions, "Use my calendar" and "Just ask me instead", directly before the system alert. That is the two-button pre-alert pattern the HIG advises against.

## Decision

1. **Permissions are skill data.** `SkillDescriptor.permissions` lists what a skill may need (`calendarFullAccess`, `locationWhenInUse`, `photoLibrary`). You shows each skill's permission line and a switch.
2. **Ask at first use, never at launch.** Each permission is requested the first time the owner uses the feature that needs it:
   - Find a time: when the owner starts it.
   - Pick a place: when the owner lets the agent suggest nearby places.
   - Swap photos: after the plan ends, only if the owner opted in at Confirm.

   The same rule covers the two app-level permissions Phase 1 asked for in onboarding:
   - Local Network: at the first Pair or the first request.
   - Notifications: when the owner sends a first request ("Want a heads-up when friends are up for it?").
3. **Starling's sheet before a system alert has one button.** The sheet keeps the mockup's explanation:
   - Your agent reads: when you're busy or free.
   - Never leaves your phone: event names, places, people.
   - The friend sees: only times you're both free.

   Its single button is "Continue", and it leads straight to the system alert. The system's "Don't Allow" is the opt-out, and denial falls back right away: "No problem, your agent will ask you instead." The owner can switch Find a time between "Use my calendar" and "Just ask me" in You › Skills at any time. This keeps the mockup's content while following the HIG.
4. **Fallbacks on denial, never a dead end.**
   - Calendar denied, or no calendar: ask-owner. The agent puts one `SkillQuestion` to its owner, and the interaction still completes.
   - Location denied: the owner types or picks a place.
   - Photos limited: only the selected photos are offered.
5. **Find a time reads busy and free only.** Event titles, locations, and attendees never leave the device and never enter a prompt that involves a peer's data. Availability reaches the negotiation as `TimeSlot`s only.
6. **Purpose strings name the skill's use.** For example: "Starling checks when you're busy so friends' agents can find a time without asking you. Event details stay on your iPhone." Lane C owns the calendar string, lane D location, lane E photos, and lane A Local Network.

## Consequences

- First launch has no permission alerts. Each prompt appears in context with Starling's explanation, so the system alert's purpose is clear.
- A denied permission never blocks a skill: every skill that asks has a no-permission path.
- If Oliver prefers the mockup's two-button sheet, the alternative is to present calendar versus ask-me as an ordinary in-skill choice earlier in Find a time's first run, then show the one-button sheet only for the calendar path. Either way, two buttons never sit directly before the alert.

## Sources

- EventKit, accessing the event store: https://developer.apple.com/documentation/eventkit/accessing-the-event-store
- WWDC23 "What's new in privacy" (10053): https://developer.apple.com/videos/play/wwdc2023/10053/
- HIG, Privacy: https://developer.apple.com/design/human-interface-guidelines/privacy
- `requestWhenInUseAuthorization()`: https://developer.apple.com/documentation/corelocation/cllocationmanager/requestwheninuseauthorization()
- `MKLocalSearch.Request.region`: https://developer.apple.com/documentation/mapkit/mklocalsearch/request/region
- PhotoKit, delivering an enhanced privacy experience: https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app
