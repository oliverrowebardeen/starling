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

**What lane H needs:**

0. Done on lane H's side for v1.1: the app's single Inbox loop forwards every `InboxEvent` to `DownService.handle(_:)` (`AppServices.inboxEvents`), and approved consent is remembered for 10 minutes within one intent (F request 5, ADR 0142).
1. A way to build F's `DownService` on the app's `Outbox` (lane G's policy, the consent sheet, the audit log; `AppModel.outbox`) and the app's Inbox loop, rather than F building its own.
2. Resolved by lane G: `ConsentSheetModel` derives the PSI notice from the disclosure itself, so the app no longer needs a separate privacy flag.
3. Confirmation that one merged `OwnerRules` per intent (standing rules plus the intent, most restrictive sharing wins; ADR 0141) is what F wants in `DownIntent.rules`.

**Meanwhile:** Debug builds use `ScriptedDownService` driven from Developer > Fakes; Release shows "Down? isn't in this build yet".
