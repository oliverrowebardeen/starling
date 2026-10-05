import Foundation
@testable import StarlingWiFiAware

struct FakeRadioError: Error, Hashable {
    let reason: String
}

/// One direction of a fake connection. `take` returns nil once closed.
actor FakeMailbox {
    private var queue: [AwareMessage] = []
    private var waiter: CheckedContinuation<AwareMessage?, Never>?
    private(set) var isClosed = false

    func put(_ message: AwareMessage) {
        guard !isClosed else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: message)
        } else {
            queue.append(message)
        }
    }

    func close() {
        isClosed = true
        waiter?.resume(returning: nil)
        waiter = nil
    }

    func take() async -> AwareMessage? {
        if !queue.isEmpty { return queue.removeFirst() }
        if isClosed || Task.isCancelled { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.close() }
        }
    }
}

/// One end of a fake Wi-Fi Aware connection. Closing either end closes both,
/// like a TCP connection.
struct FakeChannel: AwareChannel {
    let inbox: FakeMailbox
    let outbox: FakeMailbox
    let device: AwareDeviceID?

    func send(_ content: Data, type: Int) async throws {
        guard !(await outbox.isClosed) else { throw FakeRadioError(reason: "closed") }
        await outbox.put(AwareMessage(type: type, content: content))
    }

    func receive() async throws -> AwareMessage {
        guard let message = await inbox.take() else { throw FakeRadioError(reason: "closed") }
        return message
    }

    func remoteDevice() async -> AwareDeviceID? { device }

    func close() async {
        await inbox.close()
        await outbox.close()
    }
}

/// The airspace shared by fake phones: who is paired, in range, publishing,
/// and discoverable, plus the open connections between them.
actor FakeAir {
    private struct Pair: Hashable {
        let a: String, b: String
        init(_ x: String, _ y: String) { (a, b) = x < y ? (x, y) : (y, x) }
    }

    private var nextDeviceID: AwareDeviceID = 100
    /// `deviceIDs[phone][other]` is the ID `phone` uses for `other`.
    private var deviceIDs: [String: [String: AwareDeviceID]] = [:]
    private var outOfRange: Set<Pair> = []
    /// `(observer, target)` pairs where the observer's browser misses the target.
    private var hidden: Set<[String]> = []
    private var browsers: [String: [UUID: (devices: AwareDevices, continuation: AsyncStream<Set<AwareDeviceID>>.Continuation)]] = [:]
    private var listeners: [String: [UUID: (devices: AwareDevices, continuation: AsyncStream<FakeChannel>.Continuation)]] = [:]
    private var pairedObservers: [String: [UUID: AsyncStream<Set<AwareDeviceID>>.Continuation]] = [:]
    /// Models FB21527009: two phones that both publish and subscribe to
    /// each other never connect.
    var symmetricLinksFail = false
    private var channels: [(pair: Pair, channel: FakeChannel)] = []
    private(set) var dialCount: [String: Int] = [:]
    /// `dialsTo[phone][target]` counts dial attempts from `phone` to `target`.
    private var dialsTo: [String: [String: Int]] = [:]
    /// Phones whose dials fail even though the target is discovered.
    private var failingDials: Set<String> = []

    func radio(for phone: String) -> FakeRadio {
        FakeRadio(phone: phone, air: self)
    }

    /// Pairs two phones, as DeviceDiscoveryUI would. Each gets its own ID for the other.
    func pair(_ a: String, _ b: String) {
        deviceIDs[a, default: [:]][b] = nextID()
        deviceIDs[b, default: [:]][a] = nextID()
        for phone in [a, b] {
            for continuation in (pairedObservers[phone] ?? [:]).values { continuation.yield(pairedSet(phone)) }
        }
        publishDiscovery()
    }

    func setSymmetricLinksFail(_ fail: Bool) { symmetricLinksFail = fail }

    /// Whether `phone` publishes to, and subscribes to, `target`.
    func roles(of phone: String, toward target: String) -> (publishes: Bool, subscribes: Bool) {
        guard let id = deviceIDs[phone]?[target] else { return (false, false) }
        let publishes = (listeners[phone] ?? [:]).values.contains { $0.devices.contains(id) }
        let subscribes = (browsers[phone] ?? [:]).values.contains { $0.devices.contains(id) }
        return (publishes, subscribes)
    }

    private func pairedSet(_ phone: String) -> Set<AwareDeviceID> { Set((deviceIDs[phone] ?? [:]).values) }

    func addPairedObserver(_ phone: String) -> (UUID, AsyncStream<Set<AwareDeviceID>>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Set<AwareDeviceID>.self)
        pairedObservers[phone, default: [:]][id] = continuation
        continuation.yield(pairedSet(phone))
        return (id, stream)
    }

    func removePairedObserver(_ phone: String, _ id: UUID) {
        pairedObservers[phone]?[id]?.finish()
        pairedObservers[phone]?[id] = nil
    }

    /// The system name `phone` has for the device with `id`: the other
    /// phone's name plus "'s iPhone", like a real default name.
    func pairedDevice(_ id: AwareDeviceID, seenBy phone: String) -> WiFiAwarePairedDevice? {
        guard let target = deviceIDs[phone]?.first(where: { $0.value == id })?.key else { return nil }
        return WiFiAwarePairedDevice(id: id, name: "\(target.capitalized)'s iPhone")
    }

    func deviceID(of target: String, seenBy phone: String) -> AwareDeviceID? {
        deviceIDs[phone]?[target]
    }

    /// Moving out of range drops every connection between the two phones.
    func setInRange(_ a: String, _ b: String, _ inRange: Bool) async {
        if inRange { outOfRange.remove(Pair(a, b)) } else { outOfRange.insert(Pair(a, b)) }
        if !inRange {
            let dropped = channels.filter { $0.pair == Pair(a, b) }
            channels.removeAll { $0.pair == Pair(a, b) }
            for entry in dropped { await entry.channel.close() }
        }
        publishDiscovery()
    }

    /// Makes `observer`'s browser miss `target` (one-sided discovery).
    func setHidden(_ target: String, from observer: String, _ isHidden: Bool) {
        if isHidden { hidden.insert([observer, target]) } else { hidden.remove([observer, target]) }
        publishDiscovery()
    }

    /// Drops every connection between two phones without moving them apart,
    /// like a link failure while both stay discovered.
    func dropConnections(_ a: String, _ b: String) async {
        let dropped = channels.filter { $0.pair == Pair(a, b) }
        channels.removeAll { $0.pair == Pair(a, b) }
        for entry in dropped { await entry.channel.close() }
    }

    func dials(from phone: String, to target: String) -> Int {
        dialsTo[phone]?[target] ?? 0
    }

    func setDialsFail(_ phone: String, _ fail: Bool) {
        if fail { failingDials.insert(phone) } else { failingDials.remove(phone) }
    }

    /// Open connections between two phones.
    func openConnectionCount(_ a: String, _ b: String) async -> Int {
        var open = 0
        for entry in channels where entry.pair == Pair(a, b) {
            if !(await entry.channel.inbox.isClosed) { open += 1 }
        }
        return open
    }

    // MARK: Radio operations

    func addBrowser(_ phone: String, _ devices: AwareDevices) -> (UUID, AsyncStream<Set<AwareDeviceID>>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Set<AwareDeviceID>.self)
        browsers[phone, default: [:]][id] = (devices, continuation)
        continuation.yield(visibleDevices(for: phone, browsing: devices))
        return (id, stream)
    }

    func removeBrowser(_ phone: String, _ id: UUID) {
        browsers[phone]?[id]?.continuation.finish()
        browsers[phone]?[id] = nil
    }

    func addListener(_ phone: String, _ devices: AwareDevices) -> (UUID, AsyncStream<FakeChannel>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: FakeChannel.self)
        listeners[phone, default: [:]][id] = (devices, continuation)
        publishDiscovery()
        return (id, stream)
    }

    func removeListener(_ phone: String, _ id: UUID) {
        listeners[phone]?[id]?.continuation.finish()
        listeners[phone]?[id] = nil
        publishDiscovery()
    }

    func connect(from phone: String, to device: AwareDeviceID) throws -> FakeChannel {
        dialCount[phone, default: 0] += 1
        if let named = deviceIDs[phone]?.first(where: { $0.value == device })?.key {
            dialsTo[phone, default: [:]][named, default: 0] += 1
        }
        guard !failingDials.contains(phone) else { throw FakeRadioError(reason: "dial failed") }
        guard let target = deviceIDs[phone]?.first(where: { $0.value == device })?.key,
              let me = deviceIDs[target]?[phone],
              (browsers[phone] ?? [:]).values.contains(where: { $0.devices.contains(device) }),
              visible(target, to: phone),
              let listener = listeners[target]?.values.first(where: { $0.devices.contains(me) })?.continuation
        else { throw FakeRadioError(reason: "device \(device) not reachable") }
        if symmetricLinksFail {
            let mine = roles(of: phone, toward: target)
            let theirs = roles(of: target, toward: phone)
            if mine.publishes && mine.subscribes && theirs.publishes && theirs.subscribes {
                throw FakeRadioError(reason: "symmetric roles never connect")
            }
        }

        let toTarget = FakeMailbox()
        let toCaller = FakeMailbox()
        let callerEnd = FakeChannel(inbox: toCaller, outbox: toTarget, device: device)
        let targetEnd = FakeChannel(inbox: toTarget, outbox: toCaller, device: deviceIDs[target]?[phone])
        channels.append((Pair(phone, target), callerEnd))
        listener.yield(targetEnd)
        return callerEnd
    }

    // MARK: Private

    private func nextID() -> AwareDeviceID {
        defer { nextDeviceID += 1 }
        return nextDeviceID
    }

    /// In range, not hidden, and `target` publishes to `phone`.
    private func visible(_ target: String, to phone: String) -> Bool {
        guard let me = deviceIDs[target]?[phone] else { return false }
        let publishing = (listeners[target] ?? [:]).values.contains { $0.devices.contains(me) }
        return publishing && !outOfRange.contains(Pair(phone, target)) && !hidden.contains([phone, target])
    }

    /// Paired devices this browser covers that are visible to this phone.
    private func visibleDevices(for phone: String, browsing devices: AwareDevices) -> Set<AwareDeviceID> {
        Set((deviceIDs[phone] ?? [:]).compactMap { target, id in
            devices.contains(id) && visible(target, to: phone) ? id : nil
        })
    }

    private func publishDiscovery() {
        for (phone, streams) in browsers {
            for browser in streams.values { browser.continuation.yield(visibleDevices(for: phone, browsing: browser.devices)) }
        }
    }
}

struct FakeRadio: AwareRadio {
    let phone: String
    let air: FakeAir

    func preflight() throws {}

    func pairedDevices(_ update: @escaping @Sendable (Set<AwareDeviceID>) async -> Void) async throws {
        let (id, stream) = await air.addPairedObserver(phone)
        for await devices in stream { await update(devices) }
        await air.removePairedObserver(phone, id)
    }

    func browse(_ devices: AwareDevices, _ update: @escaping @Sendable (Set<AwareDeviceID>) async -> Void) async throws {
        let (id, stream) = await air.addBrowser(phone, devices)
        for await devices in stream { await update(devices) }
        await air.removeBrowser(phone, id)
    }

    func listen(_ devices: AwareDevices, _ accept: @escaping @Sendable (any AwareChannel) async -> Void) async throws {
        let (id, stream) = await air.addListener(phone, devices)
        await withTaskGroup(of: Void.self) { group in
            for await channel in stream {
                group.addTask {
                    await accept(channel)
                    await channel.close()
                }
            }
            group.cancelAll()
        }
        await air.removeListener(phone, id)
    }

    func dial(_ device: AwareDeviceID, _ body: @escaping @Sendable (any AwareChannel) async -> Void) async throws {
        let channel = try await air.connect(from: phone, to: device)
        await body(channel)
        await channel.close()
    }

    func pairedDevice(_ device: AwareDeviceID) async -> WiFiAwarePairedDevice? {
        await air.pairedDevice(device, seenBy: phone)
    }
}
