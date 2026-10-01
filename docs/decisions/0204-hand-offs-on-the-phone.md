# ADR 0204: How the hand-offs and their local records work

- Status: Proposed
- Date: 2026-10-01
- Owner: P15-A (Shell and IA)

## Context

ADR 0018 (approved) chooses the hand-offs: Add to Calendar with `EKEventEditViewController`, Message the group with an optional per-friend contact link from `CNContactPickerViewController`, Directions in Maps, and plans through App Intents. It leaves the storage of contact links and the plan timeline's record of hand-offs to the shell.

Verified in the iOS 27 SDK headers and Apple's documentation (2026-10-01): `EKEventEditViewController` "for creating, editing, and deleting calendar events"; `MFMessageComposeViewController.canSendText()` and `recipients`; `CNContactPickerViewController` "an interface for picking contacts"; `MKMapItem.openInMaps(launchOptions:)`, `MKMapItem(location:address:)` (iOS 26, replacing the deprecated placemark initializer), and `MKMapItemRequest(mapItemIdentifier:)` (iOS 18); `AppShortcutsProvider`.

## Decision

1. **Contact links and hand-off records live in one local file**, `plan-notes.json`, through the same `JSONFile` helper as ADR 0200: protected until first unlock, excluded from backup, never sent. A contact link keeps the contact identifier, the name as it appears in Contacts, and one phone number, the first the contact has. Unpairing a friend removes their link.
2. **Message the group** fills recipients only from links. With no links at all, the first tap offers "Who's who", where the owner can link each friend, then opens Messages. Friends without a link are left for the owner to add in Messages.
3. **Add to Calendar** pre-fills the title ("Boba with Maya and Jake"), start, end, and the place's name. A plan with no time has no Add to Calendar.
4. **Directions** opens the venue by its Maps identifier when the plan has one, otherwise by its coordinate and name, otherwise a Maps search for the name. Maps routes from the owner's location itself.
5. **The timeline records hand-offs the owner completed**: a saved calendar event, a sent message, and opening directions. Cancelled sheets are not recorded.
6. **App Intents**: one intent, "What's my next plan?", with App Shortcuts phrases. It reads the interactions on the phone and answers in a sentence; it changes nothing and sends nothing.
   - **It runs only on an unlocked phone.** `AppIntent.authenticationPolicy` defaults to `alwaysAllowed`, which "allows the intent to run without authentication, including when the device is locked", and the answer names friends, a time, and a place. Every intent that reads plans or names sets `requiresLocalDeviceAuthentication` ("requires the person to unlock the device running the intent"). Review of PR #54, finding 1.
   - The intents live in StarlingFeatures, made available to the app with `AppIntentsPackage`, so `swift test` checks the policy of every intent in `StarlingIntents.readingPersonalData`. The app registers the live plan reader with `AppDependencyManager` at launch. The built app's `Metadata.appintents` lists `StarlingFeatures.NextPlanIntent` with that policy.

## Consequences

- Hand-offs never need a permission, and none sends anything by itself.
- A contact's number can change in Contacts after linking; the link keeps the old one until the owner links again. Re-reading the contact would need Contacts access, which ADR 0018 avoids.
- Muse and Dots stay out of scope (ADR 0018 decision 5).

## Sources

- `EKEventEditViewController`: https://developer.apple.com/documentation/eventkitui/ekeventeditviewcontroller
- `MFMessageComposeViewController.recipients`: https://developer.apple.com/documentation/messageui/mfmessagecomposeviewcontroller/recipients
- `CNContactPickerViewController`: https://developer.apple.com/documentation/contactsui/cncontactpickerviewcontroller
- `MKMapItem.openInMaps(launchOptions:)`: https://developer.apple.com/documentation/mapkit/mkmapitem/openinmaps(launchoptions:)
- `AppShortcutsProvider`: https://developer.apple.com/documentation/appintents/appshortcutsprovider
- `AppIntent.authenticationPolicy`: https://developer.apple.com/documentation/appintents/appintent/authenticationpolicy
- `IntentAuthenticationPolicy.requiresLocalDeviceAuthentication`: https://developer.apple.com/documentation/appintents/intentauthenticationpolicy/requireslocaldeviceauthentication
- `AppIntentsPackage`: https://developer.apple.com/documentation/appintents/appintentspackage
- iOS 27.0 SDK headers: `MapKit/MKMapItem.h`, `MapKit/MKMapItemRequest.h`, `MapKit/MKMapItemIdentifier.h`
- ADRs 0018 and 0200
