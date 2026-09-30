# ADR 0111: Wi-Fi Aware services, entitlement, and pairing views

- Status: Proposed (lane E2), 2026-09-30
- Owner: E2. Wi-Fi Aware transport

## Context

- An app declares each Wi-Fi Aware service under `WiFiAwareServices` in Info.plist, with `Publishable`, `Subscribable`, or both. A name is `_` plus 1 to 15 characters from `a-z`, `A-Z`, `0-9`, and `-`, with at least one letter and no leading or trailing hyphen, then `._tcp` or `._udp`. "Invalid service names in the `Info.plist` cause your app to crash," and so does a service with neither key (Adopting Wi-Fi Aware).
- The `com.apple.developer.wifi-aware` entitlement is an array of `Publish` and/or `Subscribe`, iOS and iPadOS 26.0 and later only. It needs the Wi-Fi Aware capability enabled for the App ID.
- An app "can only publish a given service at most once per device" (Adopting Wi-Fi Aware). `DevicePairingView` publishes the service it is given, and the transport's listener publishes the link service the whole time it runs.
- `.userSpecifiedDevices` "includes only new devices the user pairs via DeviceDiscoveryUI" and "will throw an error if used with a `NetworkListener`." The transport uses `.allPairedDevices`.
- `DDDevicePairingAccess.permanent` grants "the app permanent access to the device selected by the user for future use"; `.default` uses "the system's default access."
- Paired devices belong to the app, not to a service: DeviceDiscoveryUI adds them to "the set of `WAPairedDevice.Devices` that your app may connect to on-demand" (`WAPairedDevice`).

## Decision

1. **Two services**, both `Publishable` and `Subscribable`:
   - `_starling-link._tcp` (name 13 characters): links, used by `WiFiAwareTransport`.
   - `_starling-pair._tcp` (name 13 characters): the pairing views only. A separate service lets the pairing sheet publish while the transport keeps publishing the link service, instead of stopping the transport during pairing.
   Both names are checked against Apple's rules in `WiFiAwareServicesTests`, because a bad name only shows up as a crash on a device.
2. **Entitlement** `com.apple.developer.wifi-aware` = `[Publish, Subscribe]`.
3. **Pairing views** wrap DeviceDiscoveryUI and request `.permanent` access, because friends pair once and expect it to last:
   - `WiFiAwarePairingView` (`DevicePairingView`, pairing service, `.userSpecifiedDevices`): makes this phone discoverable.
   - `WiFiAwareDevicePicker` (`DevicePicker`, pairing service, `.userSpecifiedDevices`): finds the friend's phone and pairs.
   - `WiFiAwarePairedDevicesList` with the `WiFiAwarePairedDevices` model: rows for `WAPairedDevice.allDevices`. Removing a pairing happens in Settings.
   None of these expose WiFiAware types, so the app does not import the framework. Both views show their `fallback` when the service is missing from Info.plist, instead of crashing.
4. OS pairing is only the link-level trust step. The Starling identity is pinned afterwards by lane E1's ceremony over the new link (ADR 0003): after pairing, the transport reports `peerAvailable` for a `PeerID` that is not yet in the `PairedPeerStore`.

## Snippet for lane H

Lane E2 applied this snippet on its branch without committing it, ran `xcodegen generate`, and built for `generic/platform=iOS Simulator` with `CODE_SIGNING_ALLOWED=NO`: the build succeeded, the generated entitlements file held both capabilities, and the built app's Info.plist held both services.

`App/project.yml`, under `targets.Starling` (XcodeGen writes the entitlements file from `properties`):

```yaml
    entitlements:
      path: Config/Starling.entitlements
      properties:
        com.apple.developer.wifi-aware: [Publish, Subscribe]
```

and in the same target's existing `dependencies` list:

```yaml
      - package: StarlingTransport
        product: StarlingWiFiAware
```

The resulting entitlement:

```xml
<key>com.apple.developer.wifi-aware</key>
<array>
    <string>Publish</string>
    <string>Subscribe</string>
</array>
```

`App/Sources/Info.plist`, next to the existing `NSBonjourServices`:

```xml
<key>WiFiAwareServices</key>
<dict>
    <key>_starling-link._tcp</key>
    <dict>
        <key>Publishable</key>
        <dict/>
        <key>Subscribable</key>
        <dict/>
    </dict>
    <key>_starling-pair._tcp</key>
    <dict>
        <key>Publishable</key>
        <dict/>
        <key>Subscribable</key>
        <dict/>
    </dict>
</dict>
```

The names must match `StarlingWiFiAwareService.link` and `.pairing` exactly.

## Consequences

- **Owner action:** enable the Wi-Fi Aware capability for `com.oliverrowebardeen.starling` in the developer portal before any device build.
- Two services cost a second publish while the pairing sheet is up. `WACapabilities.maximumPublishableServices` is only known at run time. If device tests show the pairing view failing while the transport runs, or a device paired on the pairing service not linking on the link service, the fallback is one service for both, with lane H stopping the transport while the pairing sheet is up.
- Whether the system shows a PIN is still unverified by a primary source (`docs/research/phase-0-verification.md`); the device checklist records what appears.
- Wi-Fi Aware needs iPhone 12 or later and does not run in the Simulator. `WiFiAwareSupport.isSupported` reports it.

## Sources

- Adopting Wi-Fi Aware: https://developer.apple.com/documentation/wifiaware/adopting-wi-fi-aware
- `com.apple.developer.wifi-aware`: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.wifi-aware
- `WAPairedDevice`: https://developer.apple.com/documentation/wifiaware/wapaireddevice
- `WAPublisherListener.Devices.userSpecifiedDevices`: https://developer.apple.com/documentation/wifiaware/wapublisherlistener/devices/userspecifieddevices
- `DDDevicePairingAccess.permanent`: https://developer.apple.com/documentation/devicediscoveryui/dddevicepairingaccess/permanent
- `DevicePicker`: https://developer.apple.com/documentation/devicediscoveryui/devicepicker
- `DevicePairingView`: https://developer.apple.com/documentation/devicediscoveryui/devicepairingview
- iOS 27 SDK interfaces in Xcode 27.0: `WiFiAware.swiftinterface`, `_DeviceDiscoveryUI_SwiftUI.swiftinterface`
