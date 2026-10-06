# ADR 0018: Hand-offs to Calendar, Messages, Maps, and Siri

- Status: Accepted (the owner approved the contact link, decision 2, on 2026-09-30). Decision 5, Muse and Dots, stays open and out of Phase 1.5 scope.
- Date: 2026-09-30
- Owner: Orchestrator

## Context

The lifecycle's Hand off step (ADR 0011) sends a confirmed plan to other apps: Add to Calendar, Message the group, Directions, and "Siri/Muse/Dots" (Phase 1.5 sections 3 and 4). The mockups show these:

- "It's a plan": Add to Calendar ("No permission needed"), Message the group ("Opens Messages with Maya and Jake").
- "Plan detail": Message group and Directions.

Verified (2026-09-30):

- **Calendar.** EventKitUI's `EKEventEditViewController` adds an event with no calendar permission (ADR 0013).
- **Messages.** `MFMessageComposeViewController.recipients` is an optional `[String]`, and Apple's docs describe each entry as a phone number. `canSendText()` must be checked first.
- **Contacts picker.** `CNContactPickerViewController` "does not need access to the user's contacts and the user will not be prompted".
- **Maps.** `MKMapItem.openInMaps(launchOptions:)` with `MKLaunchOptionsDirectionsModeKey`: Maps routes from the user's current location itself, so Starling needs no location permission.

Starling has no phone numbers by design: no accounts, and pairing exchanges keys only (brief 2.2). "Opens Messages with Maya and Jake" therefore has no recipients to fill in.

## Decision

1. **Add to Calendar** presents `EKEventEditViewController`, pre-filled from the `Plan`: title from the activity, start and end from the time, location from the `PlaceChoice` name. It needs no permission, as the mockup says.
2. **Message the group, proposed.** Each friend can optionally be linked to a contact on this phone, chosen with `CNContactPickerViewController`.
   - The link is a local mapping from `PeerID` to a contact identifier and phone number. It is never sent and never leaves the phone, and it needs no Contacts permission.
   - Message the group fills `recipients` from the linked friends. Unlinked friends are left for the owner to add in Messages.
   - The first time the owner taps Message the group with no links, Starling offers "Link Maya to a contact" and explains that the link stays on this phone.
   - Without links, Messages opens with no recipients.
3. **Directions** opens Apple Maps at the `PlaceChoice`, by Maps item identifier when known, or by coordinate and name.
4. **Siri and system intents.** Plans are exposed through App Intents (for example "What's my next plan?"), so Siri, Shortcuts, and Spotlight can read them. App Intents is the system surface; no third-party integration is assumed.
5. **Muse and Dots: open question.** The prompt names them as hand-off targets. They are not in the brief or the repo. Oliver to say what they are before any work is planned.

## Consequences

- Every hand-off opens another app with the owner in control; none sends anything by itself.
- The contact link is new local data, stored with the paired-friend record on the device. It is not part of `PairedPeer`'s wire or pairing data.

## Sources

- `MFMessageComposeViewController.recipients`: https://developer.apple.com/documentation/messageui/mfmessagecomposeviewcontroller/recipients
- `CNContactPickerViewController`: https://developer.apple.com/documentation/contactsui/cncontactpickerviewcontroller
- `MKMapItem.openInMaps(launchOptions:)`: https://developer.apple.com/documentation/mapkit/mkmapitem/openinmaps(launchoptions:)
- EventKit, accessing the event store: https://developer.apple.com/documentation/eventkit/accessing-the-event-store
- Mockups "It's a plan" and "Plan detail"
