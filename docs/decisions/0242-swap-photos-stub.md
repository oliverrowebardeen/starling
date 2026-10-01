# ADR 0242: Swap photos ships flagged off, picking with the system picker

- Status: Proposed
- Date: 2026-10-01
- Owner: P15-E (Chaining and audit)

## Context

The Phase 1.5 prompt ships Swap photos flagged off, "only far enough to prove chaining hooks". ADR 0013 lists its permission as Photos, requested after the plan ends and only if the owner opted in at Confirm, and says limited library access must offer only the photos the owner selected. Lane E owns the photos purpose string.

Verified against Apple's documentation (2026-10-01):

- "Selecting Photos and Videos in iOS" (PhotoKit): with `PHPickerViewController` or `PhotosPicker`, "Apps don't need to request photo library permission", "Displaying the photo library doesn't need user permission because it's running in a separate process", and "An app can't take screenshots of content and can only read the assets that the user selects."
- `PhotosPicker` (PhotosUI, iOS 16 and macOS 13 and later) has `init(_:selection:maxSelectionCount:selectionBehavior:matching:preferredItemEncoding:)`.
- A frame is at most 60 KiB (`ProtocolLimits.maxFrameBytes`), so photos cannot travel as envelope values.

## Decision

1. **The descriptor is `SampleSkills.swapPhotos`**, in `Packages/Skills/SwapPhotos` (module `StarlingSwapPhotos`), with `ChainTrigger.afterPlanEnds`. It stays out of `SkillFlags.phase1_5`. It keeps `photoLibrary` in its permissions because the full skill matches photos to the plan's time, which reads the library; the link consent therefore lists photo access.
2. **Pick with the system picker; request no permission.** `SwapPhotosPicker` wraps `PhotosPicker`, shown only for a pending Swap photos question. Because the picker runs out of process, the app never asks for photo library access, needs no purpose string, and can read only the photos the owner picks. "Offer only selected photos" holds by construction. A library-reading path (and `NSPhotoLibraryUsageDescription`) waits for the full skill.
3. **What the stub does.**
   - The one who opted in: when the plan ends (ADR 0240), the service asks its owner to pick photos. The pick sends one offer, the photo count under the photos topic, to everyone else in the plan, with the skill and `chainedFrom`, through the Outbox. Acceptances are collected.
   - A friend: an offer from someone in a plan this phone was in creates an invitee card and nothing else: no picker, no permission, no start. "Share" sends an acceptance of exactly the offered terms, with the offer in `OutboundContext.accepting`, so the policy treats it as a yes to the friend's own terms (ADR 0019 amendment 10); a pass sends nothing ("If you pass, they just won't see it").
   - A newer offer from the same friend replaces the card at the next revision. A send's denial or failure is reported only if its step is still current (ADR 0011 amendment 14), and withdrawing, shutting down, or ending an interaction cancels every send of it still waiting on a sheet or the policy's re-check (there can be several: an acceptance of an older offer and of the newer one).
   - Moving the photos themselves is Phase 4's (brief 2.8 and 5). The initiator's interaction stays negotiating until it expires, and the friend's stays confirmed.
4. **The coordinator applies `.started`.** For an initiator, the lifecycle coordinator applies `.started` when the owner sends (here, when the schedule hands the link over), before calling `SkillService.start`; the service never emits it (Orchestrator's answer to `docs/requests/P15-E.md`, recorded in ADR 0011). `start` emits only the pick question.
5. **Invite only, retired when it ends** (Core v2.1, ADR 0021). Swap photos declares `sendModes: [.invite]`, as ADR 0020 requires of a skill not built on mutual reveal. Every send carries mode `invite` and `OutboundContext(interaction:)`; a request in another mode is refused, and an envelope in another mode is ignored, so a quiet ask never becomes a card. Every ending (a pass, a failed or denied send, a withdrawal, an interaction `restore(_:)` reports failed or receives already ended) retires the conversation through `Outbox.retire`, which records it in the app's `ConversationLedger` and cancels its sends still queued (ADR 0021). An offer for a retired conversation, or when the ledger cannot answer, opens nothing, so a pass is never followed by the same card, across launches too.

## Consequences

- The after-plan-ends hook is proven end to end without a device (`AfterPlanEndsHookTests`), and no photo library alert can appear in Phase 1.5, flag on or off.
- A friend's offer shows a photo count only. The threat model should note that the count leaves under the photos topic.

## Sources

- Selecting Photos and Videos in iOS: https://developer.apple.com/documentation/photokit/selecting-photos-and-videos-in-ios
- `PhotosPicker`: https://developer.apple.com/documentation/photosui/photospicker
- `PHPickerViewController`: https://developer.apple.com/documentation/photosui/phpickerviewcontroller
- ADR 0010, ADR 0012, ADR 0013; Phase 1.5 prompt, sections 2 and 5
