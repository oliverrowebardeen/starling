import Foundation

/// TLV message types on a Wi-Fi Aware link. The same values and meaning as
/// LocalP2P's link protocol, whose enum is internal to its target.
package enum AwareMessageType: Int, Sendable {
    /// First message in each direction: a `LinkHello`.
    case hello = 1
    /// One Starling frame.
    case frame = 2
}

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

/// The Wi-Fi Aware operations `WiFiAwareTransport` needs. The real one
/// (`WiFiAwareRadio`) exists only on iOS; tests use an in-memory fake, so the
/// transport's link handling runs under `swift test` on macOS (ADR 0110).
package protocol AwareRadio: Sendable {
    /// Throws if the radio cannot work at all (for example, the service is
    /// missing from Info.plist), so `start()` can report it.
    func preflight() throws

    /// Subscribes until cancelled or failed. Calls `update` with the full set
    /// of paired devices currently publishing the link service.
    func browse(_ update: @escaping @Sendable (Set<AwareDeviceID>) async -> Void) async throws

    /// Publishes until cancelled or failed. Calls `accept` for every incoming
    /// connection; the connection lives while `accept` runs.
    func listen(_ accept: @escaping @Sendable (any AwareChannel) async -> Void) async throws

    /// Connects to a discovered device and runs `body` with the connection,
    /// closing it when `body` returns. Throws if the device is not discovered.
    func dial(_ device: AwareDeviceID, _ body: @escaping @Sendable (any AwareChannel) async -> Void) async throws
}

/// The radio asks for `browse` or `listen` to run again at once, for example
/// because the set of paired devices changed.
package struct AwareRadioRestart: Error, Hashable, Sendable {
    package init() {}
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

    package init(
        helloTimeout: Duration,
        fallbackDelay: Duration,
        retryDelay: @escaping @Sendable (Int) -> Duration?,
        radioRestartDelay: @escaping @Sendable (Int) -> Duration
    ) {
        self.helloTimeout = helloTimeout
        self.fallbackDelay = fallbackDelay
        self.retryDelay = retryDelay
        self.radioRestartDelay = radioRestartDelay
    }
}
