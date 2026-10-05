import Foundation
import StarlingCore
// The macOS SDK ships a WiFiAware module too, but marks every symbol
// unavailable on macOS and Mac Catalyst, so `canImport` alone is not enough.
#if canImport(WiFiAware) && os(iOS) && !targetEnvironment(macCatalyst)
import Network
import WiFiAware
#endif

/// Whether this device can use Wi-Fi Aware at all. False on every platform
/// but iOS (iPhone 12 and later), and in the Simulator.
public enum WiFiAwareSupport {
    public static var isSupported: Bool {
        #if canImport(WiFiAware) && os(iOS) && !targetEnvironment(macCatalyst) && !targetEnvironment(simulator)
        WACapabilities.supportedFeatures.contains(.wifiAware)
        #else
        false
        #endif
    }
}

#if canImport(WiFiAware) && os(iOS) && !targetEnvironment(macCatalyst)
package enum WiFiAwareRadioError: Error, Hashable, Sendable {
    case unsupported
    /// The service is missing from `WiFiAwareServices` in Info.plist (ADR 0111).
    case serviceNotDeclared(String)
    case deviceNotDiscovered(AwareDeviceID)
}

extension WAPublishableService {
    static var starlingLink: WAPublishableService? { allServices[StarlingWiFiAwareService.link] }
    static var starlingPairing: WAPublishableService? { allServices[StarlingWiFiAwareService.pairing] }
}

extension WASubscribableService {
    static var starlingLink: WASubscribableService? { allServices[StarlingWiFiAwareService.link] }
    static var starlingPairing: WASubscribableService? { allServices[StarlingWiFiAwareService.pairing] }
}

extension WiFiAwareTransport {
    /// A transport over the device's Wi-Fi Aware radio, linking to every
    /// device paired through `WiFiAwarePairingView` or `WiFiAwareDevicePicker`.
    /// `trace` receives one line per link event, for Debug diagnostics.
    public init(localPeer: PeerID, trace: (@Sendable (String) -> Void)? = nil) {
        self.init(localPeer: localPeer, radio: WiFiAwareRadio(), roleStore: DefaultsAwareRoleStore(), trace: trace)
    }
}

/// The real Wi-Fi Aware radio: publishes or subscribes
/// `StarlingWiFiAwareService.link` for the paired devices the transport
/// names, with TCP and TLV framing on every connection (ADR 0110, ADR 0260).
package actor WiFiAwareRadio: AwareRadio {
    /// Endpoints from the latest browse results, by paired device.
    private var endpoints: [AwareDeviceID: WAEndpoint] = [:]

    package init() {}

    package nonisolated func preflight() throws {
        guard WACapabilities.supportedFeatures.contains(.wifiAware) else { throw WiFiAwareRadioError.unsupported }
        guard WAPublishableService.starlingLink != nil, WASubscribableService.starlingLink != nil else {
            throw WiFiAwareRadioError.serviceNotDeclared(StarlingWiFiAwareService.link)
        }
    }

    package func pairedDevices(_ update: @escaping @Sendable (Set<AwareDeviceID>) async -> Void) async throws {
        let all = WAPairedDevice.allDevices
        await update(Self.pairedDeviceIDs(try await all.current()))
        for try await devices in all { await update(Self.pairedDeviceIDs(devices)) }
    }

    /// Subscribes to the link service on `devices` until cancelled. The
    /// transport restarts it when the devices it covers change.
    package func browse(_ devices: AwareDevices, _ update: @escaping @Sendable (Set<AwareDeviceID>) async -> Void) async throws {
        guard let service = WASubscribableService.starlingLink else {
            throw WiFiAwareRadioError.serviceNotDeclared(StarlingWiFiAwareService.link)
        }
        let browser = NetworkBrowser(for: .wifiAware(.connecting(to: try await Self.subscriberDevices(devices), from: service)))
        try await browser.run { [weak self] found in
            let byDevice = Dictionary(found.map { ($0.device.id, $0) }, uniquingKeysWith: { first, _ in first })
            await self?.setEndpoints(byDevice)
            await update(Set(byDevice.keys))
        }
    }

    /// Publishes the link service to `devices` until cancelled. Restarting
    /// a listener closes the links it accepted, so the transport restarts it
    /// only when the devices it covers change.
    package func listen(_ devices: AwareDevices, _ accept: @escaping @Sendable (any AwareChannel) async -> Void) async throws {
        guard let service = WAPublishableService.starlingLink else {
            throw WiFiAwareRadioError.serviceNotDeclared(StarlingWiFiAwareService.link)
        }
        let listener = try NetworkListener(
            for: .wifiAware(.connecting(to: service, from: try await Self.publisherDevices(devices))),
            using: Self.parameters()
        )
        try await listener.run { connection in
            await accept(WiFiAwareChannel(connection: connection))
        }
    }

    private static func selected(_ ids: Set<AwareDeviceID>) async throws -> [WAPairedDevice] {
        let current = try await WAPairedDevice.allDevices.current() ?? [:]
        return ids.compactMap { current[$0] }
    }

    private static func subscriberDevices(_ devices: AwareDevices) async throws -> WASubscriberBrowser.Devices {
        switch devices {
        case .all: .allPairedDevices
        case .only(let ids): .selected(try await selected(ids))
        }
    }

    private static func publisherDevices(_ devices: AwareDevices) async throws -> WAPublisherListener.Devices {
        switch devices {
        case .all: .allPairedDevices
        case .only(let ids): .selected(try await selected(ids))
        }
    }

    package func dial(_ device: AwareDeviceID, _ body: @escaping @Sendable (any AwareChannel) async -> Void) async throws {
        guard let endpoint = endpoints[device] else { throw WiFiAwareRadioError.deviceNotDiscovered(device) }
        let connection = NetworkConnection(to: endpoint, using: Self.parameters())
        await body(WiFiAwareChannel(connection: connection))
    }

    /// Network framework reports Wi-Fi Aware failures as `NWError.wifiAware`
    /// codes; `wifiAware` maps them to `WAError` (for example -11992 is
    /// `noPairedDevices`), which says what went wrong (Apple DTS, forum
    /// thread 794271).
    package nonisolated func describe(_ error: any Error) -> String {
        if let network = error as? NWError, let aware = network.wifiAware { return "Wi-Fi Aware: \(aware)" }
        return String(describing: error)
    }

    package func pairedDevice(_ device: AwareDeviceID) async -> WiFiAwarePairedDevice? {
        guard let devices = try? await WAPairedDevice.allDevices.current(), let found = devices[device] else { return nil }
        return WiFiAwarePairedDevice(found)
    }

    private func setEndpoints(_ byDevice: [AwareDeviceID: WAEndpoint]) {
        endpoints = byDevice
    }

    /// TCP with the LocalP2P TLV framing: a 16-bit length caps messages at
    /// 64 KiB inside the framer. Keepalives and a retransmit limit notice a
    /// friend who walked away in about 10 seconds instead of never (TN3213,
    /// "Overriding protocol defaults"). `bulk` is Apple's recommended mode;
    /// both sides must use the same one.
    private static func parameters() -> NWParametersBuilder<TLV> {
        .parameters {
            TLV(type: UInt8.self, length: UInt16.self) {
                TCP()
                    .keepalive(idleTimeInSeconds: 5, count: 3, intervalInSeconds: 2)
                    .retransmitConnectionDropTime(10)
            }
        }
        .wifiAware { $0.performanceMode = .bulk }
    }

    // MARK: Paired devices

    private static func pairedDeviceIDs(_ devices: WAPairedDevice.Devices?) -> Set<AwareDeviceID> {
        Set(devices?.keys.map { $0 } ?? [])
    }
}

/// One Wi-Fi Aware connection. Closes when the last reference goes away,
/// which is when the transport's link task ends.
struct WiFiAwareChannel: AwareChannel {
    let connection: NetworkConnection<TLV>

    func send(_ content: Data, type: Int) async throws {
        try await connection.send(content, type: type)
    }

    func receive() async throws -> AwareMessage {
        let message = try await connection.receive()
        return AwareMessage(type: message.metadata.type, content: message.content)
    }

    func remoteDevice() async -> AwareDeviceID? {
        guard let path = connection.currentPath, let aware = try? await path.wifiAware else { return nil }
        return aware.endpoint.device.id
    }
}
#endif
