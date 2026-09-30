import SwiftUI
#if canImport(DeviceDiscoveryUI) && canImport(WiFiAware) && os(iOS) && !targetEnvironment(macCatalyst)
import DeviceDiscoveryUI
import WiFiAware
#endif

/// A list of the paired devices, tracking the system list while visible. The
/// default row is the device name. To embed rows in another list instead,
/// use `ForEach(model.devices)` and call `model.track()` from that screen's
/// `.task`.
public struct WiFiAwarePairedDevicesList<Row: View>: View {
    private let model: WiFiAwarePairedDevices
    private let row: (WiFiAwarePairedDevice) -> Row

    public init(_ model: WiFiAwarePairedDevices, @ViewBuilder row: @escaping (WiFiAwarePairedDevice) -> Row) {
        self.model = model
        self.row = row
    }

    public var body: some View {
        // The task hangs off the List, which always exists. On a ForEach it
        // would run once per row, and never with no devices yet.
        List(model.devices) { device in
            row(device)
        }
        .task { await model.track() }
    }
}

extension WiFiAwarePairedDevicesList where Row == Text {
    public init(_ model: WiFiAwarePairedDevices) {
        self.init(model) { Text($0.name) }
    }
}

#if canImport(DeviceDiscoveryUI) && canImport(WiFiAware) && os(iOS) && !targetEnvironment(macCatalyst)

/// Makes this phone discoverable so a friend can pair with it from
/// `WiFiAwareDevicePicker` on their phone. The system runs the PIN
/// exchange. One person uses this view and the other uses the picker.
///
/// Advertises `StarlingWiFiAwareService.pairing`, not the link service, so
/// it can run while `WiFiAwareTransport` is publishing (ADR 0111). Shows
/// `fallback` when the device cannot pair over Wi-Fi Aware or the service is
/// missing from Info.plist.
public struct WiFiAwarePairingView<Label: View, Fallback: View>: View {
    private let label: Label
    private let fallback: Fallback

    public init(@ViewBuilder label: () -> Label, @ViewBuilder fallback: () -> Fallback) {
        self.label = label()
        self.fallback = fallback()
    }

    public var body: some View {
        if let service = WAPublishableService.starlingPairing {
            DevicePairingView(.wifiAware(.connecting(to: service, from: .userSpecifiedDevices)), access: .permanent) {
                label
            } fallback: {
                fallback
            }
        } else {
            fallback
        }
    }
}

/// Finds a nearby friend who is showing `WiFiAwarePairingView` and pairs
/// with their phone. The system presents the picker full screen and runs
/// the PIN exchange. `onPaired` receives the device once the system paired
/// it; `WiFiAwareTransport` then links to it without further calls.
public struct WiFiAwareDevicePicker<Label: View, Fallback: View>: View {
    private let onPaired: (WiFiAwarePairedDevice) -> Void
    private let label: Label
    private let fallback: Fallback

    public init(
        onPaired: @escaping (WiFiAwarePairedDevice) -> Void = { _ in },
        @ViewBuilder label: () -> Label,
        @ViewBuilder fallback: () -> Fallback
    ) {
        self.onPaired = onPaired
        self.label = label()
        self.fallback = fallback()
    }

    public var body: some View {
        if let service = WASubscribableService.starlingPairing {
            DevicePicker(
                .wifiAware(.connecting(to: .userSpecifiedDevices, from: service)),
                access: .permanent,
                onSelect: { endpoint in onPaired(WiFiAwarePairedDevice(endpoint.device)) },
                label: { label },
                fallback: { fallback }
            )
        } else {
            fallback
        }
    }
}
#endif
