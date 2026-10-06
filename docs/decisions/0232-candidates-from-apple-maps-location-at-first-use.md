# ADR 0232: Candidates from Apple Maps, location at first use, typed places when denied

- Status: Accepted (code merged on main; status updated 2026-10-06)
- Date: 2026-10-01
- Owner: P15-D (Pick a place)

## Context

Pick a place needs candidate venues before anything is sent. ADR 0013 makes Location When In Use a Pick a place permission. It is asked the first time the owner lets the agent suggest nearby places, behind Starling's one-button sheet, with manual entry on denial. ADR 0013 inferred, without an Apple statement, that MapKit search near a typed area needs no permission.

Verified 2026-10-01:

- `MKLocalSearch.Request.region` is "merely a hint to the search engine". `regionPriority` (iOS 18) can make it required.
- `MKLocalSearch.start()` has an async form. `MKMapItemRequest(mapItemIdentifier:)` (iOS 18) looks a venue up by identifier, and `mapItem` is async.
- `requestWhenInUseAuthorization()` needs `NSLocationWhenInUseUsageDescription`. It needs the app in the foreground to show a prompt, and does nothing unless the status is not determined.
- A live search ("coffee" near a named landmark) ran from a Mac with no location permission. It returned 8 venues with identifiers and categories, and an identifier lookup returned the same name. That confirms the inference.

## Decision

1. **Candidates are found in Compose,** before `start`:
   - `PlaceFinder` searches `PlaceSearching` and reads `LocationAccess`.
   - The app stages the result in `StagedCandidates` under the interaction's ID.
   - `start` takes the candidates once. It throws `noCandidates` or `nothingFitsYourLimits`, so the owner stays in Compose.
2. **A typed area needs no permission.** The area is resolved to a region with one search, then the kind ("dinner") is searched in it with `regionPriority = .required`.
3. **Nearby asks at first use, through Starling's sheet.** `find(_:near: .nearby)` never shows the system alert. With the status not determined, it returns `needsLocationPermission`:
   - The app shows `PickAPlaceSkill.locationSheet`: "Find places near you"; reads: where you are, only while it looks for places; never leaves your phone: your location; friends see: only the places you suggest; one Continue button.
   - Continue calls `allowLocationAndFind`, which shows the system alert. Granted searches within 2 km of one position.
4. **Denied, restricted, no position, no results, or a failed search fall back to typed places** (`PlaceCandidate.manual`). The note after Don't Allow is "No problem. Type a place or an area instead."
5. **Purpose string** (`PickAPlaceSkill.locationPurpose`): "Starling uses your location only while it finds places near you. Your location stays on your iPhone; friends see only the places you suggest."
6. **Where things go.**
   - The owner's position is used only as the center of a search and is never in a message.
   - Candidates carry venues' coordinates only, and a typed place has none.
   - Apple Maps receives the search terms and the region, as any Maps search does. On a friend's phone, Apple Maps receives the identifiers of the venues it is asked about.
7. **Adapters.** `PickAPlaceMapKit` holds `MapKitPlaceSearch` and `CoreLocationAccess` (main actor), so the `PickAPlace` library stays Foundation and StarlingCore only and every path is tested with fakes.

## Consequences

- First launch has no location prompt, and a denied permission never blocks the skill.
- Search results come with category kinds but no price or diet facts (ADR 0230).
- Every Pick a place on a friend's phone makes up to 8 Apple Maps lookups, which needs a network connection. Without one, the facts are unknown and the venues are judged as unchecked.
- Lane A owns the Info.plist key, the sheet, and the Compose UI (docs/requests/P15-D.md).

## Sources

- `MKLocalSearch.Request.region`: https://developer.apple.com/documentation/mapkit/mklocalsearch/request/region
- `MKLocalSearch.Request.regionPriority`: https://developer.apple.com/documentation/mapkit/mklocalsearch/request/regionpriority
- `MKLocalSearch.start()`: https://developer.apple.com/documentation/mapkit/mklocalsearch/start(completionhandler:)
- `MKMapItemRequest`: https://developer.apple.com/documentation/mapkit/mkmapitemrequest
- `requestWhenInUseAuthorization()`: https://developer.apple.com/documentation/corelocation/cllocationmanager/requestwheninuseauthorization()
- `NSLocationWhenInUseUsageDescription`: https://developer.apple.com/documentation/bundleresources/information-property-list/nslocationwheninuseusagedescription
- `requestLocation()`: https://developer.apple.com/documentation/corelocation/cllocationmanager/requestlocation()
- HIG, Privacy (one-button pre-alert screen): https://developer.apple.com/design/human-interface-guidelines/privacy
- ADR 0013; `Packages/Skills/PickAPlace/Tests/PickAPlaceTests/MapKitAdapterTests.swift` (live test)
