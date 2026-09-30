import Foundation
import StarlingCore
import StarlingLocalP2P

extension AwareTiming {
    /// LocalP2P's dial fallback and redial backoff (1, 2, 4, 8, 16 seconds,
    /// then give up while the device stays discovered), and radio restarts
    /// capped at 30 seconds.
    package static let standard = AwareTiming(
        helloTimeout: .seconds(5),
        fallbackDelay: DialRule.fallbackDelay,
        retryDelay: { RetryPolicy.delay(forAttempt: $0) },
        radioRestartDelay: { attempt in .seconds(min(1 << min(max(attempt - 1, 0), 5), 30)) }
    )
}

/// Links between paired friends over Wi-Fi Aware (ADR 0110).
///
/// Wi-Fi Aware roles are asymmetric: a publisher listens and a subscriber
/// dials. Every phone does both for the same service, and this type hides
/// the difference: callers see symmetric peers, one link per paired device,
/// identified by the `PeerID` in the link hello. `LinkTable` decides who
/// dials and which duplicate survives. A link that drops is redialed with
/// bounded backoff while the device stays discovered, and again whenever it
/// is rediscovered.
///
/// Each connection is TCP with TLV framing and the LocalP2P link hello.
/// Wi-Fi Aware encrypts the link between OS-paired devices, but that binds
/// devices, not Starling identities: the `PeerID` in a hello is a claim until
/// the secure channel (ADR 0003) verifies it.
///
/// Requires the Wi-Fi Aware entitlement and the `WiFiAwareServices`
/// Info.plist entry in ADR 0111. Runs only on iOS devices; on other platforms
/// the type exists so shared code compiles, but nothing constructs one.
public actor WiFiAwareTransport: Transport {
    private struct LiveLink {
        let channel: any AwareChannel
        let task: Task<Void, Never>
    }

    private enum State { case idle, started, stopped }

    public nonisolated let kind = TransportKind.wifiAware
    public nonisolated let localPeer: PeerID
    public nonisolated let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let radio: any AwareRadio
    private let timing: AwareTiming

    private var state = State.idle
    private var table: LinkTable
    private var live: [UUID: LiveLink] = [:]
    /// Paired devices currently publishing the service, from the browser.
    private var discovered: Set<AwareDeviceID> = []
    /// In-flight outgoing connections, by device.
    private var dialTasks: [AwareDeviceID: Task<Void, Never>] = [:]
    /// Scheduled dials (fallback waits and retries), by device.
    private var waitTasks: [AwareDeviceID: Task<Void, Never>] = [:]
    /// Consecutive failed attempts per device; reset when a link comes up.
    private var retryAttempts: [AwareDeviceID: Int] = [:]
    /// Grace timers for provisional links.
    private var graceTasks: [UUID: Task<Void, Never>] = [:]
    private var browseTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?

    package init(localPeer: PeerID, radio: any AwareRadio, timing: AwareTiming = .standard) {
        self.localPeer = localPeer
        self.radio = radio
        self.timing = timing
        table = LinkTable(localPeer: localPeer)
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    /// Throws `TransportError.failed` if Wi-Fi Aware cannot run at all, for
    /// example when the service is missing from Info.plist. Discovery and
    /// publishing failures after that are retried in the background.
    public func start() async throws {
        switch state {
        case .started: return
        case .stopped: throw TransportError.stopped
        case .idle: break
        }
        do {
            try radio.preflight()
        } catch {
            throw TransportError.failed(String(describing: error))
        }
        state = .started

        browseTask = Task { [weak self] in
            await self?.keepRunning("browse") { [weak self] radio in
                // Whatever ends the browse, its results are stale afterwards.
                do {
                    try await radio.browse { [weak self] devices in await self?.discoveryChanged(devices) }
                } catch {
                    await self?.discoveryChanged([])
                    throw error
                }
                await self?.discoveryChanged([])
            }
        }
        listenTask = Task { [weak self] in
            await self?.keepRunning("listen") { [weak self] radio in
                try await radio.listen { [weak self] channel in
                    await self?.runLink(channel, direction: .incoming, device: nil)
                }
            }
        }
    }

    public func send(_ frame: Frame, to peer: PeerID) async throws {
        guard state == .started else { throw state == .idle ? TransportError.notStarted : TransportError.stopped }
        guard let link = table.activeLink(to: peer), let channel = live[link.id]?.channel else {
            throw TransportError.peerUnreachable(peer)
        }
        do {
            try await channel.send(frame.bytes, type: AwareMessageType.frame.rawValue)
        } catch {
            throw TransportError.failed(String(describing: error))
        }
    }

    public func stop() async {
        guard state != .stopped else { return }
        state = .stopped
        browseTask?.cancel()
        listenTask?.cancel()
        // Pending dials and waits must not outlive the transport.
        for task in dialTasks.values { task.cancel() }
        for task in waitTasks.values { task.cancel() }
        for task in graceTasks.values { task.cancel() }
        dialTasks.removeAll()
        waitTasks.removeAll()
        graceTasks.removeAll()
        discovered.removeAll()
        for link in table.removeAll() {
            live[link.id]?.task.cancel()
            if link.state == .active { continuation.yield(.peerUnavailable(link.peer)) }
        }
        live.removeAll()
        continuation.finish()
    }

    // MARK: - Radio

    /// Runs a browse or listen, restarting it with backoff when it fails or
    /// ends, until the transport stops.
    private func keepRunning(_ label: String, _ operation: @escaping @Sendable (any AwareRadio) async throws -> Void) async {
        var failures = 0
        while state == .started, !Task.isCancelled {
            do {
                try await operation(radio)
                failures += 1
            } catch is AwareRadioRestart {
                failures = 0
                continue
            } catch {
                failures += 1
                log("\(label) failed: \(error)")
            }
            guard state == .started, !Task.isCancelled else { return }
            try? await Task.sleep(for: timing.radioRestartDelay(failures))
        }
    }

    // MARK: - Discovery and redial

    private func discoveryChanged(_ devices: Set<AwareDeviceID>) {
        guard state == .started else { return }
        discovered = devices
        // Stop waiting on devices that disappeared, and give them a fresh
        // retry budget for when they come back.
        for (device, task) in waitTasks where !devices.contains(device) {
            task.cancel()
            waitTasks[device] = nil
        }
        retryAttempts = retryAttempts.filter { devices.contains($0.key) }
        for device in devices.sorted() { connect(to: device, after: .zero) }
    }

    /// Connects to a discovered device unless already linked or trying.
    private func connect(to device: AwareDeviceID, after delay: Duration) {
        guard canConnect(to: device) else { return }
        let wait = table.dialsImmediately(device) ? delay : max(delay, timing.fallbackDelay)
        guard wait > .zero else {
            dial(device)
            return
        }
        waitTasks[device] = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.waitFinished(device)
        }
    }

    private func canConnect(to device: AwareDeviceID) -> Bool {
        state == .started && discovered.contains(device) && !table.isLinked(device)
            && dialTasks[device] == nil && waitTasks[device] == nil
    }

    private func waitFinished(_ device: AwareDeviceID) {
        waitTasks[device] = nil
        guard canConnect(to: device) else { return }
        dial(device)
    }

    private func dial(_ device: AwareDeviceID) {
        let radio = radio
        dialTasks[device] = Task { [weak self] in
            do {
                try await radio.dial(device) { [weak self] channel in
                    await self?.runLink(channel, direction: .outgoing, device: device)
                }
            } catch {
                await self?.log("dial failed: \(error)")
            }
            await self?.finishedDialing(device)
        }
    }

    private func finishedDialing(_ device: AwareDeviceID) {
        dialTasks[device] = nil
        // Covers a dial that never linked and an outgoing link that dropped.
        retry(device)
    }

    /// Schedules a bounded, backed-off redial if the device is still
    /// discovered and nothing is linked or in flight.
    private func retry(_ device: AwareDeviceID) {
        guard canConnect(to: device) else { return }
        let attempt = retryAttempts[device, default: 0] + 1
        guard let delay = timing.retryDelay(attempt) else {
            log("giving up on device \(device) until it is rediscovered")
            return
        }
        retryAttempts[device] = attempt
        connect(to: device, after: delay)
    }

    // MARK: - Links

    /// Runs one connection until it closes: hello, admission, receive loop.
    private func runLink(_ channel: any AwareChannel, direction: LinkDirection, device dialed: AwareDeviceID?) async {
        let hello: LinkHello
        do {
            hello = try await exchangeHello(on: channel)
        } catch {
            log("\(direction) hello failed: \(error)")
            return
        }
        var device = dialed
        if device == nil { device = await channel.remoteDevice() }
        guard state == .started, !Task.isCancelled else { return }

        let id = UUID()
        let remote = hello.peer
        // The receive loop runs in its own task so a replaced link can be
        // closed by cancelling it. It cannot deliver before admission below:
        // delivery needs this actor, which does not suspend until then.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop(channel, link: id, from: remote)
        }
        let admission = table.admit(id: id, peer: remote, direction: direction, device: device)
        guard let linkState = admission.state else {
            task.cancel()
            return
        }
        live[id] = LiveLink(channel: channel, task: task)
        for closed in admission.closed { close(closed) }
        for peer in admission.unavailable { continuation.yield(.peerUnavailable(peer)) }
        if let device { retryAttempts[device] = nil }
        if admission.announce { continuation.yield(.peerAvailable(remote)) }
        if linkState == .provisional { startGrace(for: id) }

        // Cancelling this task (Stop, or a cancelled dial) must reach the loop.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        linkEnded(id)
    }

    private func exchangeHello(on channel: any AwareChannel) async throws -> LinkHello {
        let ours = try LinkHello(peer: localPeer, serviceName: StarlingWiFiAwareService.link).encoded
        let timeout = timing.helloTimeout
        return try await withThrowingTaskGroup(of: LinkHello.self) { group in
            group.addTask {
                try await channel.send(ours, type: AwareMessageType.hello.rawValue)
                let message = try await channel.receive()
                guard message.type == AwareMessageType.hello.rawValue else {
                    throw ValidationError("WiFiAware", "expected hello")
                }
                return try LinkHello(decoding: message.content)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TransportError.failed("hello timed out")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func receiveLoop(_ channel: any AwareChannel, link id: UUID, from remote: PeerID) async {
        while !Task.isCancelled {
            do {
                let message = try await channel.receive()
                guard message.type == AwareMessageType.frame.rawValue else {
                    log("unexpected message type \(message.type) from \(remote.short); closing")
                    return
                }
                deliver(try Frame(message.content), link: id, from: remote)
            } catch {
                return
            }
        }
    }

    private func deliver(_ frame: Frame, link id: UUID, from remote: PeerID) {
        // Only the current link for this peer may deliver.
        guard state == .started, table.current(id) != nil else { return }
        // The peer sent on a provisional link, so it treats it as active.
        activate(id)
        continuation.yield(.received(frame, from: remote))
    }

    private func startGrace(for id: UUID) {
        let wait = timing.fallbackDelay
        graceTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.activate(id)
        }
    }

    private func activate(_ id: UUID) {
        graceTasks.removeValue(forKey: id)?.cancel()
        guard state == .started, let link = table.current(id) else { return }
        if table.activate(id) {
            if let device = link.device { retryAttempts[device] = nil }
            continuation.yield(.peerAvailable(link.peer))
        }
    }

    private func close(_ id: UUID) {
        graceTasks.removeValue(forKey: id)?.cancel()
        live.removeValue(forKey: id)?.task.cancel()
    }

    private func linkEnded(_ id: UUID) {
        graceTasks.removeValue(forKey: id)?.cancel()
        live[id] = nil
        guard let link = table.remove(id), state == .started else { return }
        if link.state == .active { continuation.yield(.peerUnavailable(link.peer)) }
        // An outgoing link's dial task is still running here, so this is a
        // no-op for it and `finishedDialing` retries instead.
        if let device = table.device(for: link.peer) ?? link.device { retry(device) }
    }

    // MARK: - Test hooks

    /// Dials and waits still pending. Zero after `stop()`.
    package var pendingTaskCount: Int { dialTasks.count + waitTasks.count + graceTasks.count }

    /// The link table, for tests.
    package var linkTable: LinkTable { table }

    private func log(_ message: String) {
        #if DEBUG
        print("[WiFiAware \(localPeer.short)] \(message)")
        #endif
    }
}
