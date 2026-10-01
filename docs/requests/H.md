# Lane H requests

Open requests from lane H (App features). Nothing here blocks lane H: each has a local workaround in place.

## 1. Run the app's feature tests in `Tools/test-all.sh` and CI (Orchestrator)

**Status:** done in Core v1.1 (`Tools/test-all.sh` scans `App/*/Package.swift`).

**What:** add `App/Features` to the packages `Tools/test-all.sh` runs by default, for example by also scanning `"$root"/App/*/Package.swift`.

**Why:** lane H's view models and presentation logic live in the `StarlingFeatures` package under `App/Features` (ADR 0140). The script only scans `Packages/*` and `Tools/*`, so CI does not run its 66 tests today.

**Meanwhile:** lane H runs `Tools/test-all.sh App/Features` (the script accepts a path) before every commit.

## 2. Guard "no fakes in Release" in CI (Orchestrator)

**What:** a CI step that builds the Release configuration for the simulator and fails if the binary contains `StarlingFakes` symbols:

```
xcodebuild build -project App/Starling.xcodeproj -scheme Starling -configuration Release \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES -derivedDataPath build
test "$(nm build/Build/Products/Release-iphonesimulator/Starling.app/Starling | grep -c StarlingFakes)" = 0
```

**Status:** the Orchestrator will add it after PR #15 merges.

**Why:** the exclusion depends on Xcode naming the linked object `StarlingFakes.o` (ADR 0140). CI only builds Debug today, so a Release regression would go unnoticed.

**Meanwhile:** checked by hand on every lane H commit (result: 0).

## 3. How the app starts a pairing session (lanes E1 and E2, via the Orchestrator)

**What lane H needs:** a way to get a `StarlingCore.PairingSession` for a device the owner picked. The app takes it as `AppServices.makePairingSession`, currently `@Sendable () async throws -> any PairingSession`. Once E2's picker exists, lane H expects the shape to become "E2's view hands back a picked device, E1 starts a session for it", for example `(PickedDevice) async throws -> any PairingSession`. The picker goes in `DeviceDiscoverySlot` (`App/Sources/Views/PairingView.swift`, marked "LANE E2 SLOT").

**Also:** after `.paired`, the app saves the peer again with the owner's chosen nickname (`PairedPeerStore.save` is an upsert). If E1's session already pins the peer, that only updates the name.

**Status:** lane E2's views are wired: the pairing screen's slot shows `WiFiAwarePairingView` and `WiFiAwareDevicePicker` where Wi-Fi Aware runs, and Developer > Wi-Fi Aware runs `WiFiAwareTransport` for E2's checklist (ADR 0143). What remains is E1's side: how the app starts Starling's code-check ceremony with the friend the system just paired.

**Meanwhile:** Debug builds use `ScriptedPairingSession` for the code check; Release shows "Friends isn't in this build yet".

## 4. Down service construction and PSI privacy flag (lane F, via the Orchestrator)

**Status:** resolved by lane F's answers (`docs/requests/F.md`, "Answers to lane H") and wired in ADR 0144: Down is built on the app's `Outbox`, the Inbox loop passes it every event and greets peers with `hello`, the review shows F's errors and the matching note from `psiProvider.isPrivate`, intent constraints come before standing ones, and `shutdown()` runs on teardown. Debug builds run it against a simulated friend; Release keeps "Down? isn't in this build yet" until a PSI provider exists outside `StarlingFakes`.

## 5. Finding the phone to pair with (lanes E1 and E2, via the Orchestrator)

**What lane H needs:** a way for the pairing screen to learn the key-derived `PeerID` of a nearby phone that is reachable but not yet pinned, so the owner can pick it and the app can call `PairingService.pair(with:nickname:)`. For example:

- `PairingService.candidates: AsyncStream<Set<PeerID>>` (or a `status`-style query) listing peers seen on the pairing link without a pin; or
- `WiFiAwareDevicePicker`'s `onPaired` reporting the `PeerID` from that device's link hello once it arrives, not only the OS device.

**Why:** `pair(with:)` takes the friend's `PeerID` (docs/requests/E1.md item 2.6). Today nothing in the app can see one before pinning:

- `SecureTransport` emits `peerAvailable` only once a session with a pinned key is live (its doc comment);
- `PairingService` is the single consumer of `pairingLink` events and keeps them to its ceremonies;
- `WiFiAwareDevicePicker` returns a `WiFiAwarePairedDevice` (OS device ID and name), not a `PeerID`.

So after the system pairs two phones over Wi-Fi Aware, the app cannot offer "pair with this phone".

**Also, for the record:** E1's API gives one `SecureTransport` per link (LocalP2P and Wi-Fi Aware), while the app's `Outbox` and `Inbox` take one transport. Lane H will add a composite `Transport` in `App/Features` that merges both links' events and sends to whichever link has the peer. No request; noted so E1 and the Orchestrator see the shape.

**Status:** resolved for Wi-Fi Aware by lane E2's `WiFiAwareTransport.peerID(for:waitingUpTo:)` (PR #38), which the pairing screen uses for the picked phone. For LocalP2P, and for the phone that made itself discoverable, lane H keeps its workaround (ADR 0145): a `LinkWatcher` wraps each raw link before its `SecureTransport`, passes events through, and records the peers the link reports; the pairing screen lists those that are not pinned. An API from E1 or E2 would let the app drop the wrapper.

## 6. Renaming a friend through the PinAuthority (lane E1, via the Orchestrator)

**What:** a way to change a pinned friend's nickname that is ordered with unpair and pairing commits, for example `PinAuthority.rename(_ peer: PeerID, to nickname: String) async throws`, refusing a peer that is being removed.

**Why:** E1 asks the app never to write the paired-peer store directly. A rename is a store write (`save` of the same key with a new nickname), and if it raced an unpair it could put a removed pin back.

**Status:** resolved. Lane E1 merged `PinAuthority.rename` (#36), and both builds rename through it.
