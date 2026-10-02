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
        self.init(localPeer: localPeer, radio: WiFiAwareRadio(), trace: trace)
    }
}

/// The real Wi-Fi Aware radio: publishes and subscribes
/// `StarlingWiFiAwareService.link` for all paired devices, with TCP and
/// TLV framing on every connection (ADR 0110).
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

    /// Subscribes to paired devices publishing the link service. Waits for
    /// at least one paired device first, and asks for a restart when the set
    /// of paired devices changes, so a friend paired while the app runs is
    /// found without relaunching.
    package func browse(_ update: @escaping @Sendable (Set<AwareDeviceID>) async -> Void) async throws {
        guard let service = WASubscribableService.starlingLink else {
            throw WiFiAwareRadioError.serviceNotDeclared(StarlingWiFiAwareService.link)
        }
        let paired = try await Self.waitForPairedDevices()

        enum Ended { case browser, pairedDevicesChanged, pairedDevicesUnobservable }
        try await withThrowingTaskGroup(of: Ended.self) { group in
            group.addTask { [weak self] in
                let browser = NetworkBrowser(for: .wifiAware(.connecting(to: .allPairedDevices, from: service)))
                try await browser.run { [weak self] found in
                    let byDevice = Dictionary(found.map { ($0.device.id, $0) }, uniquingKeysWith: { first, _ in first })
                    await self?.setEndpoints(byDevice)
                    await update(Set(byDevice.keys))
                }
                return .browser
            }
            group.addTask {
                try await Self.changed(from: paired) ? .pairedDevicesChanged : .pairedDevicesUnobservable
            }
            defer { group.cancelAll() }
            while let ended = try await group.next() {
                switch ended {
                case .browser: return
                case .pairedDevicesChanged: throw AwareRadioRestart()
                case .pairedDevicesUnobservable: continue
                }
            }
        }
    }

    /// Publishes the link service to all paired devices. Unlike `browse`,
    /// this does not restart when a device is paired, because restarting a
    /// listener closes the links it accepted. A friend paired later still
    /// links, because our browser finds them and dials.
    package func listen(_ accept: @escaping @Sendable (any AwareChannel) async -> Void) async throws {
        guard let service = WAPublishableService.starlingLink else {
            throw WiFiAwareRadioError.serviceNotDeclared(StarlingWiFiAwareService.link)
        }
        _ = try await Self.waitForPairedDevices()
        let listener = try NetworkListener(
            for: .wifiAware(.connecting(to: service, from: .allPairedDevices)),
            using: Self.parameters()
        )
        try await listener.run { connection in
            await accept(WiFiAwareChannel(connection: connection))
        }
    }

    package func dial(_ device: AwareDeviceID, _ body: @escaping @Sendable (any AwareChannel) async -> Void) async throws {
        guard let endpoint = endpoints[device] else { throw WiFiAwareRadioError.deviceNotDiscovered(device) }
        let connection = NetworkConnection(to: endpoint, using: Self.parameters())
        await body(WiFiAwareChannel(connection: connection))
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

    /// The current paired devices, once there is at least one. A listener or
    /// browser for `allPairedDevices` has nothing to do before that.
    private static func waitForPairedDevices() async throws -> Set<AwareDeviceID> {
        let current = pairedDeviceIDs(try await WAPairedDevice.allDevices.current())
        if !current.isEmpty { return current }
        for try await devices in WAPairedDevice.allDevices where !devices.isEmpty {
            return pairedDeviceIDs(devices)
        }
        throw CancellationError()
    }

    /// True once the paired set differs from `known`; false if the system
    /// stops reporting changes.
    private static func changed(from known: Set<AwareDeviceID>) async throws -> Bool {
        for try await devices in WAPairedDevice.allDevices where pairedDeviceIDs(devices) != known {
            return true
        }
        return false
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
