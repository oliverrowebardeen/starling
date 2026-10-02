import Foundation
import StarlingCore
import StarlingLocalP2P

extension AwareTiming {
    /// LocalP2P's dial fallback and redial backoff (1, 2, 4, 8, 16 seconds,
    /// then give up while the device stays discovered), radio restarts
    /// capped at 30 seconds, and fixed roles with 10-second random slots
    /// for devices whose role is not settled yet (ADR 0260).
    package static let standard = AwareTiming(
        helloTimeout: .seconds(5),
        fallbackDelay: DialRule.fallbackDelay,
        retryDelay: { RetryPolicy.delay(forAttempt: $0) },
        radioRestartDelay: { attempt in .seconds(min(1 << min(max(attempt - 1, 0), 5), 30)) },
        roles: .fixed(slot: .seconds(10))
    )
}

/// Links between paired friends over Wi-Fi Aware (ADR 0110).
///
/// Wi-Fi Aware roles are asymmetric: a publisher listens and a subscriber
/// dials. This type hides the difference: callers see symmetric peers, one
/// link per paired device, identified by the `PeerID` in the link hello.
///
/// With fixed roles (ADR 0260, the default), each phone takes one role per
/// paired device, because a developer reports that two phones that both
/// publish and subscribe never connect (FB21527009):
///
/// - The phone whose owner picked the other in `WiFiAwareDevicePicker`
///   subscribes (`pickedDevice(_:)`); the phone that was discoverable
///   publishes to a device paired while `expectPairing(for:)` runs.
/// - Once a hello names the peer, both phones settle on the `PeerID` rule
///   (the greater ID subscribes and dials, as `LinkArbiter` prefers) and
///   remember it across launches.
/// - A device with neither takes a random role every slot until a link
///   forms, so pairings made before this rule still meet.
///
/// `LinkTable` decides which duplicate survives. A link that drops is
/// redialed with bounded backoff while the device stays discovered, and
/// again whenever it is rediscovered.
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

    private struct DeviceWaiter {
        let continuation: CheckedContinuation<PeerID?, Never>
        let timer: Task<Void, Never>
    }

    public nonisolated let kind = TransportKind.wifiAware
    public nonisolated let localPeer: PeerID
    public nonisolated let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let radio: any AwareRadio
    private let timing: AwareTiming
    private let trace: (@Sendable (String) -> Void)?

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
    /// Callers of `peerID(for:waitingUpTo:)` waiting for a device's hello.
    private var deviceWaiters: [AwareDeviceID: [UUID: DeviceWaiter]] = [:]
    private var browseTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var pairedTask: Task<Void, Never>?
    private var slotTask: Task<Void, Never>?
    /// Bumped on every browse restart, so a stopped browse's last report
    /// cannot overwrite the new one's.
    private var browseGeneration = 0

    // Roles (ADR 0260).
    private let roleStore: any AwareRoleStore
    /// Devices paired with this app, from the radio.
    private var paired: Set<AwareDeviceID> = []
    /// Roles settled by the PeerID rule, kept across launches.
    private var settledRoles: [AwareDeviceID: AwareRole]
    /// Roles from the pairing views, until a link settles them or they lapse.
    private var tentativeRoles: [AwareDeviceID: (role: AwareRole, until: ContinuousClock.Instant)] = [:]
    /// While set, a newly paired device was paired from the other phone's picker.
    private var expectingPairingUntil: ContinuousClock.Instant?
    /// This slot's role for devices with no other role.
    private var slotRole: AwareRole = Bool.random() ? .publisher : .subscriber
    private var browsing: AwareDevices?
    private var listening: AwareDevices?

    package init(
        localPeer: PeerID, radio: any AwareRadio, timing: AwareTiming = .standard,
        roleStore: any AwareRoleStore = InMemoryAwareRoleStore(), trace: (@Sendable (String) -> Void)? = nil
    ) {
        self.localPeer = localPeer
        self.radio = radio
        self.timing = timing
        self.trace = trace
        self.roleStore = roleStore
        settledRoles = roleStore.load()
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
        pairedTask = Task { [weak self] in
            await self?.keepRunning("paired devices") { [weak self] radio in
                try await radio.pairedDevices { [weak self] devices in await self?.pairedChanged(devices) }
            }
        }
        if case .fixed(let slot) = timing.roles {
            slotTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: slot)
                    guard !Task.isCancelled else { return }
                    await self?.nextSlot()
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
            try await channel.send(frame.bytes, type: LinkMessageType.frame.rawValue)
        } catch {
            throw TransportError.failed(String(describing: error))
        }
    }

    public func stop() async {
        guard state != .stopped else { return }
        state = .stopped
        browseTask?.cancel()
        listenTask?.cancel()
        pairedTask?.cancel()
        slotTask?.cancel()
        // Pending dials and waits must not outlive the transport.
        for task in dialTasks.values { task.cancel() }
        for task in waitTasks.values { task.cancel() }
        for task in graceTasks.values { task.cancel() }
        for device in Array(deviceWaiters.keys) { resolveWaiters(for: device, with: nil) }
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

    // MARK: - Roles (ADR 0260)

    /// The owner picked `device` in `WiFiAwareDevicePicker`: this phone
    /// subscribes to it and dials, while the other phone publishes.
    public func pickedDevice(_ device: WiFiAwarePairedDevice) {
        guard case .fixed = timing.roles, settledRoles[device.id] == nil else { return }
        tentativeRoles[device.id] = (.subscriber, ContinuousClock.now.advanced(by: timing.tentativeRoleLifetime))
        log("picked device \(device.id): subscribing")
        applyRoles()
    }

    /// The pairing sheet is open here. A device paired in the next
    /// `duration` that this phone did not pick was paired from the other
    /// phone's picker, so this phone publishes to it. `pickedDevice(_:)`
    /// overrides this for the device this phone picked.
    public func expectPairing(for duration: Duration = .seconds(180)) {
        expectingPairingUntil = ContinuousClock.now.advanced(by: duration)
    }

    /// The role with `device` now, or nil to both publish and subscribe.
    package func role(for device: AwareDeviceID) -> AwareRole? {
        if let settled = settledRoles[device] { return settled }
        if let tentative = tentativeRoles[device], ContinuousClock.now < tentative.until { return tentative.role }
        switch timing.roles {
        case .symmetric: return nil
        case .fixed: return slotRole
        }
    }

    private func pairedChanged(_ devices: Set<AwareDeviceID>) {
        guard state == .started else { return }
        let added = devices.subtracting(paired)
        guard devices != paired else { return }
        paired = devices
        log("\(devices.count) paired device(s)")
        if let until = expectingPairingUntil, ContinuousClock.now < until {
            for device in added where settledRoles[device] == nil && tentativeRoles[device] == nil {
                tentativeRoles[device] = (.publisher, ContinuousClock.now.advanced(by: timing.tentativeRoleLifetime))
                log("device \(device) paired from the other phone: publishing")
            }
        }
        let forgotten = settledRoles.keys.filter { !devices.contains($0) }
        if !forgotten.isEmpty {
            for device in forgotten { settledRoles[device] = nil }
            roleStore.save(settledRoles)
        }
        // With symmetric roles the browse covers every paired device and
        // must restart to see a new one; the listener does not, because
        // restarting it closes the links it accepted (ADR 0110).
        applyRoles(restartBrowse: timing.roles == .symmetric && !added.isEmpty)
    }

    private func nextSlot() {
        guard state == .started else { return }
        let now = ContinuousClock.now
        tentativeRoles = tentativeRoles.filter { $0.value.until > now }
        guard paired.contains(where: { settledRoles[$0] == nil && tentativeRoles[$0] == nil }) else { return }
        slotRole = Bool.random() ? .publisher : .subscriber
        applyRoles()
    }

    /// A hello named the peer behind `device`: settle on the PeerID rule,
    /// which the other phone computes the same way.
    private func settleRole(_ device: AwareDeviceID, peer: PeerID) {
        guard case .fixed = timing.roles else { return }
        let role: AwareRole = LinkArbiter.preferredDirection(local: localPeer, remote: peer) == .outgoing ? .subscriber : .publisher
        tentativeRoles[device] = nil
        guard settledRoles[device] != role else { return }
        settledRoles[device] = role
        roleStore.save(settledRoles)
        log("settled as \(role) with device \(device)")
        applyRoles()
    }

    /// Runs the browse and listen the roles call for, restarting each only
    /// when the devices it covers change.
    private func applyRoles(restartBrowse: Bool = false) {
        guard state == .started else { return }
        let browse: AwareDevices?
        let listen: AwareDevices?
        switch timing.roles {
        case .symmetric:
            browse = paired.isEmpty ? nil : .all
            listen = browse
        case .fixed:
            let subscribing = paired.filter { role(for: $0) == .subscriber }
            let publishing = paired.filter { role(for: $0) == .publisher }
            browse = subscribing.isEmpty ? nil : .only(subscribing)
            listen = publishing.isEmpty ? nil : .only(publishing)
        }
        if browse != browsing || restartBrowse { runBrowse(browse) }
        if listen != listening { runListen(listen) }
    }

    private func runBrowse(_ devices: AwareDevices?) {
        browseTask?.cancel()
        browseTask = nil
        browsing = devices
        browseGeneration += 1
        discoveryChanged([], generation: browseGeneration)
        guard let devices else { return }
        let generation = browseGeneration
        browseTask = Task { [weak self] in
            await self?.keepRunning("browse") { [weak self] radio in
                // Whatever ends the browse, its results are stale afterwards.
                do {
                    try await radio.browse(devices) { [weak self] found in await self?.discoveryChanged(found, generation: generation) }
                } catch {
                    await self?.discoveryChanged([], generation: generation)
                    throw error
                }
                await self?.discoveryChanged([], generation: generation)
            }
        }
    }

    private func runListen(_ devices: AwareDevices?) {
        listenTask?.cancel()
        listenTask = nil
        listening = devices
        guard let devices else { return }
        listenTask = Task { [weak self] in
            await self?.keepRunning("listen") { [weak self] radio in
                try await radio.listen(devices) { [weak self] channel in
                    await self?.runLink(channel, direction: .incoming, device: nil)
                }
            }
        }
    }

    // MARK: - Devices

    /// The `PeerID` behind a paired device, as its link hello claimed it.
    /// Nil until a hello has arrived from that device; once learned, it stays
    /// known while the transport runs, even if the link drops.
    ///
    /// Use it to start pairing with the device the owner picked in
    /// `WiFiAwareDevicePicker`. Pass a `timeout` to wait for the hello,
    /// which arrives shortly after the system finishes pairing; the call then
    /// returns nil if the hello has not arrived in time, the calling task is
    /// cancelled, or the transport stops. The ID is a claim like any other a
    /// transport reports: the pairing ceremony's code comparison is what
    /// verifies it (ADR 0003).
    public func peerID(for device: WiFiAwarePairedDevice, waitingUpTo timeout: Duration = .zero) async -> PeerID? {
        if let peer = table.peersByDevice[device.id] { return peer }
        guard timeout > .zero, state != .stopped else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.resolveWaiter(id, for: device.id, with: nil)
                }
                deviceWaiters[device.id, default: [:]][id] = DeviceWaiter(continuation: continuation, timer: timer)
            }
        } onCancel: {
            Task { await self.resolveWaiter(id, for: device.id, with: nil) }
        }
    }

    /// The paired device whose link hello last claimed `peer`, with the name
    /// the system has for it, or nil if no Wi-Fi Aware link has named that
    /// peer. The name labels a phone; it comes from that phone, so it is
    /// never a person's name by itself (ADR 0260).
    public func pairedDevice(for peer: PeerID) async -> WiFiAwarePairedDevice? {
        guard let device = table.device(for: peer) else { return nil }
        return await radio.pairedDevice(device)
    }

    private func resolveWaiter(_ id: UUID, for device: AwareDeviceID, with peer: PeerID?) {
        guard let waiter = deviceWaiters[device]?.removeValue(forKey: id) else { return }
        if deviceWaiters[device]?.isEmpty == true { deviceWaiters[device] = nil }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: peer)
    }

    private func resolveWaiters(for device: AwareDeviceID, with peer: PeerID?) {
        for id in Array(deviceWaiters[device]?.keys ?? [:].keys) { resolveWaiter(id, for: device, with: peer) }
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
            } catch {
                failures += 1
                log("\(label) failed: \(radio.describe(error))")
            }
            guard state == .started, !Task.isCancelled else { return }
            try? await Task.sleep(for: timing.radioRestartDelay(failures))
        }
    }

    // MARK: - Discovery and redial

    private func discoveryChanged(_ devices: Set<AwareDeviceID>, generation: Int) {
        guard state == .started, generation == browseGeneration else { return }
        let appeared = devices.subtracting(discovered)
        if devices != discovered { log("discovered \(devices.count) paired device(s)") }
        discovered = devices
        // Stop waiting on devices that disappeared, and give them a fresh
        // retry budget for when they come back.
        for (device, task) in waitTasks where !devices.contains(device) {
            task.cancel()
            waitTasks[device] = nil
        }
        retryAttempts = retryAttempts.filter { devices.contains($0.key) }
        // Every update lists the whole set. Only newly discovered devices get
        // a discovery dial; devices already listed are handled by `retry`,
        // so an update about some other device cannot restart a device whose
        // retries ran out.
        for device in appeared.sorted() { connect(to: device, after: .zero) }
    }

    /// Connects to a discovered device unless already linked or trying.
    private func connect(to device: AwareDeviceID, after delay: Duration) {
        guard canConnect(to: device) else { return }
        // With fixed roles only the subscriber dials, so it never waits.
        let wait = timing.roles != .symmetric || table.dialsImmediately(device) ? delay : max(delay, timing.fallbackDelay)
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
        log("dialing device \(device)")
        let radio = radio
        dialTasks[device] = Task { [weak self] in
            do {
                try await radio.dial(device) { [weak self] channel in
                    await self?.runLink(channel, direction: .outgoing, device: device)
                }
            } catch {
                await self?.log("dial failed: \(radio.describe(error))")
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
            log("\(direction) hello failed: \(radio.describe(error))")
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
        if let device, let learned = table.peersByDevice[device] { resolveWaiters(for: device, with: learned) }
        guard let linkState = admission.state else {
            log("\(direction) link to \(remote.short) lost to an existing link")
            task.cancel()
            return
        }
        log("\(direction) link to \(remote.short) is \(linkState == .active ? "active" : "provisional")")
        live[id] = LiveLink(channel: channel, task: task)
        for closed in admission.closed { close(closed) }
        for peer in admission.unavailable { continuation.yield(.peerUnavailable(peer)) }
        if let device { retryAttempts[device] = nil }
        if admission.announce { continuation.yield(.peerAvailable(remote)) }
        if let device { settleRole(device, peer: remote) }
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
                try await channel.send(ours, type: LinkMessageType.hello.rawValue)
                let message = try await channel.receive()
                guard message.type == LinkMessageType.hello.rawValue else {
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
                guard message.type == LinkMessageType.frame.rawValue else {
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
            log("link to \(link.peer.short) is active")
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
        log("link to \(link.peer.short) closed")
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
        trace?(message)
        #if DEBUG
        print("[WiFiAware \(localPeer.short)] \(message)")
        #endif
    }
}
