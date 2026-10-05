import Foundation

/// One TLV message on a Wi-Fi Aware link. `type` is a `LinkMessageType`
/// raw value: the link protocol is LocalP2P's (ADR 0110).
package struct AwareMessage: Hashable, Sendable {
    package let type: Int
    package let content: Data

    package init(type: Int, content: Data) {
        self.type = type
        self.content = content
    }
}

/// One connection to a paired device, carrying TLV messages. It closes when
/// the task that received it from `AwareRadio` finishes or is cancelled.
package protocol AwareChannel: Sendable {
    func send(_ content: Data, type: Int) async throws
    /// The next message. Throws once the connection has closed.
    func receive() async throws -> AwareMessage
    /// The paired device on the other end, if the radio can tell. Asked after
    /// the hello, when the connection is established.
    func remoteDevice() async -> AwareDeviceID?
}

/// Which paired devices a browse or listen covers.
package enum AwareDevices: Hashable, Sendable {
    /// Every paired device, including ones paired later (`allPairedDevices`).
    case all
    /// Only these. Never empty: the transport does not browse or listen for nobody.
    case only(Set<AwareDeviceID>)

    package func contains(_ device: AwareDeviceID) -> Bool {
        switch self {
        case .all: true
        case .only(let devices): devices.contains(device)
        }
    }
}

/// This phone's part in the link with one paired device (ADR 0260). Wi-Fi
/// Aware roles are asymmetric: a publisher listens, a subscriber dials.
package enum AwareRole: String, Hashable, Sendable, Codable {
    case publisher, subscriber
}

/// The Wi-Fi Aware operations `WiFiAwareTransport` needs. The real one
/// (`WiFiAwareRadio`) exists only on iOS; tests use an in-memory fake, so the
/// transport's link handling runs under `swift test` on macOS (ADR 0110).
package protocol AwareRadio: Sendable {
    /// Throws if the radio cannot work at all (for example, the service is
    /// missing from Info.plist), so `start()` can report it.
    func preflight() throws

    /// Follows the set of devices paired with this app until cancelled,
    /// calling `update` with the current set first.
    func pairedDevices(_ update: @escaping @Sendable (Set<AwareDeviceID>) async -> Void) async throws

    /// Subscribes to `devices` until cancelled or failed. Calls `update` with
    /// the full set of those devices currently publishing the link service.
    func browse(_ devices: AwareDevices, _ update: @escaping @Sendable (Set<AwareDeviceID>) async -> Void) async throws

    /// Publishes to `devices` until cancelled or failed. Calls `accept` for
    /// every incoming connection; the connection lives while `accept` runs.
    func listen(_ devices: AwareDevices, _ accept: @escaping @Sendable (any AwareChannel) async -> Void) async throws

    /// Connects to a discovered device and runs `body` with the connection,
    /// closing it when `body` returns. Throws if the device is not discovered.
    func dial(_ device: AwareDeviceID, _ body: @escaping @Sendable (any AwareChannel) async -> Void) async throws

    /// The system's record of a paired device, for its name, or nil if it is
    /// not paired (any more).
    func pairedDevice(_ device: AwareDeviceID) async -> WiFiAwarePairedDevice?

    /// A radio error as one line for the Debug log.
    func describe(_ error: any Error) -> String
}

extension AwareRadio {
    package func describe(_ error: any Error) -> String { String(describing: error) }
}

/// Where a phone keeps the roles it settled with each paired device, so a
/// relaunch links at once. Device IDs are local to this install.
package protocol AwareRoleStore: Sendable {
    func load() -> [AwareDeviceID: AwareRole]
    func save(_ roles: [AwareDeviceID: AwareRole])
}

/// Roles kept in memory only, for tests.
package final class InMemoryAwareRoleStore: AwareRoleStore, @unchecked Sendable {
    private let lock = NSLock()
    private var roles: [AwareDeviceID: AwareRole]

    package init(_ roles: [AwareDeviceID: AwareRole] = [:]) { self.roles = roles }
    package func load() -> [AwareDeviceID: AwareRole] { lock.withLock { roles } }
    package func save(_ roles: [AwareDeviceID: AwareRole]) { lock.withLock { self.roles = roles } }
}

/// Roles kept in `UserDefaults`, keyed by this install's device IDs.
package struct DefaultsAwareRoleStore: AwareRoleStore {
    static let key = "starling.wifiAware.roles"

    package init() {}

    package func load() -> [AwareDeviceID: AwareRole] {
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] else { return [:] }
        var roles: [AwareDeviceID: AwareRole] = [:]
        for (key, value) in stored {
            if let id = AwareDeviceID(key), let role = AwareRole(rawValue: value) { roles[id] = role }
        }
        return roles
    }

    package func save(_ roles: [AwareDeviceID: AwareRole]) {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: roles.map { (String($0.key), $0.value.rawValue) }), forKey: Self.key)
    }
}

/// How the transport splits publishing and subscribing.
package enum AwareRoleMode: Hashable, Sendable {
    /// Every phone publishes and subscribes for every paired device (ADR
    /// 0110). A developer reports this never connects (FB21527009); kept for
    /// the link-table tests and as a fallback.
    case symmetric
    /// One role per device pair (ADR 0260). A device with no role yet takes
    /// a random role for each `slot` until a link to it forms.
    case fixed(slot: Duration)
}

/// Timing for `WiFiAwareTransport`. Tests shrink these.
package struct AwareTiming: Sendable {
    /// Bounds the hello exchange, including the connection opening.
    package var helloTimeout: Duration
    /// How long the side that should not dial waits before dialing anyway, and
    /// how long a provisional link waits before it becomes active.
    package var fallbackDelay: Duration
    /// Redial delay for a device that is still discovered; nil gives up.
    package var retryDelay: @Sendable (_ attempt: Int) -> Duration?
    /// Delay before restarting a browse or listen that failed.
    package var radioRestartDelay: @Sendable (_ attempt: Int) -> Duration
    /// Symmetric or fixed roles.
    package var roles: AwareRoleMode
    /// How long a role from the pairing views stands without a link before
    /// the device falls back to random roles.
    package var tentativeRoleLifetime: Duration

    package init(
        helloTimeout: Duration,
        fallbackDelay: Duration,
        retryDelay: @escaping @Sendable (Int) -> Duration?,
        radioRestartDelay: @escaping @Sendable (Int) -> Duration,
        roles: AwareRoleMode = .symmetric,
        tentativeRoleLifetime: Duration = .seconds(60)
    ) {
        self.roles = roles
        self.tentativeRoleLifetime = tentativeRoleLifetime
        self.helloTimeout = helloTimeout
        self.fallbackDelay = fallbackDelay
        self.retryDelay = retryDelay
        self.radioRestartDelay = radioRestartDelay
    }
}
