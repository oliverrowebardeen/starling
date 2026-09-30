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
    private var browsers: [String: [UUID: AsyncStream<Set<AwareDeviceID>>.Continuation]] = [:]
    private var listeners: [String: [UUID: AsyncStream<FakeChannel>.Continuation]] = [:]
    private var channels: [(pair: Pair, channel: FakeChannel)] = []
    private(set) var dialCount: [String: Int] = [:]
    /// Phones whose dials fail even though the target is discovered.
    private var failingDials: Set<String> = []

    func radio(for phone: String) -> FakeRadio {
        FakeRadio(phone: phone, air: self)
    }

    /// Pairs two phones, as DeviceDiscoveryUI would. Each gets its own ID for the other.
    func pair(_ a: String, _ b: String) {
        deviceIDs[a, default: [:]][b] = nextID()
        deviceIDs[b, default: [:]][a] = nextID()
        publishDiscovery()
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

    func addBrowser(_ phone: String) -> (UUID, AsyncStream<Set<AwareDeviceID>>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Set<AwareDeviceID>.self)
        browsers[phone, default: [:]][id] = continuation
        continuation.yield(visibleDevices(for: phone))
        return (id, stream)
    }

    func removeBrowser(_ phone: String, _ id: UUID) {
        browsers[phone]?[id]?.finish()
        browsers[phone]?[id] = nil
    }

    func addListener(_ phone: String) -> (UUID, AsyncStream<FakeChannel>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: FakeChannel.self)
        listeners[phone, default: [:]][id] = continuation
        publishDiscovery()
        return (id, stream)
    }

    func removeListener(_ phone: String, _ id: UUID) {
        listeners[phone]?[id]?.finish()
        listeners[phone]?[id] = nil
        publishDiscovery()
    }

    func connect(from phone: String, to device: AwareDeviceID) throws -> FakeChannel {
        dialCount[phone, default: 0] += 1
        guard !failingDials.contains(phone) else { throw FakeRadioError(reason: "dial failed") }
        guard let target = deviceIDs[phone]?.first(where: { $0.value == device })?.key,
              visibleDevices(for: phone).contains(device),
              let listener = listeners[target]?.values.first
        else { throw FakeRadioError(reason: "device \(device) not reachable") }

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

    /// Paired, in range, publishing, and not hidden from this phone.
    private func visibleDevices(for phone: String) -> Set<AwareDeviceID> {
        Set((deviceIDs[phone] ?? [:]).compactMap { target, id in
            let publishing = !(listeners[target] ?? [:]).isEmpty
            let reachable = !outOfRange.contains(Pair(phone, target)) && !hidden.contains([phone, target])
            return publishing && reachable ? id : nil
        })
    }

    private func publishDiscovery() {
        for (phone, streams) in browsers {
            let visible = visibleDevices(for: phone)
            for continuation in streams.values { continuation.yield(visible) }
        }
    }
}

struct FakeRadio: AwareRadio {
    let phone: String
    let air: FakeAir

    func preflight() throws {}

    func browse(_ update: @escaping @Sendable (Set<AwareDeviceID>) async -> Void) async throws {
        let (id, stream) = await air.addBrowser(phone)
        for await devices in stream { await update(devices) }
        await air.removeBrowser(phone, id)
    }

    func listen(_ accept: @escaping @Sendable (any AwareChannel) async -> Void) async throws {
        let (id, stream) = await air.addListener(phone)
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
}
