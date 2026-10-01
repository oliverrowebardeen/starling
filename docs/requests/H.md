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
