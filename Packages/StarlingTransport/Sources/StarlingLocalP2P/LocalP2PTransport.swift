import Foundation
import Network
import StarlingCore

/// Ad hoc, co-located links over Bonjour and peer-to-peer Wi-Fi (AWDL), using
/// the Network framework Swift API (ADR 0004).
///
/// Every device both advertises and browses `_starling._tcp`. For each pair,
/// the side with the greater random service name dials (`DialRule`), so there
/// is normally one connection per pair; `LinkArbiter` resolves the rare
/// duplicate. Each connection is TCP with TLV framing: a 16-bit length caps
/// messages at 64 KiB in the framer.
///
/// **Phase 0: unauthenticated and unencrypted.** Do not carry personal data.
///
/// Requires `NSLocalNetworkUsageDescription` and `NSBonjourServices`
/// (`_starling._tcp`) in the app's Info.plist.
public actor LocalP2PTransport: Transport {
    public static let serviceType = "_starling._tcp"
    static let helloTimeout: Duration = .seconds(5)

    typealias Stack = TLV
    typealias Connection = NetworkConnection<TLV>

    private struct Link {
        let id: UUID
        let direction: LinkDirection
        let serviceName: String
        let connection: Connection
        let task: Task<Void, Never>
    }

    private enum State { case idle, started, stopped }

    public nonisolated let kind = TransportKind.localP2P
    public nonisolated let localPeer: PeerID
    public nonisolated let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    /// The random service name this device advertises.
    public nonisolated let serviceName: String
    private let includePeerToPeer: Bool

    private var state = State.idle
    private var links: [PeerID: Link] = [:]
    /// In-flight outgoing connection attempts, by service name.
    private var dialTasks: [String: Task<Void, Never>] = [:]
    /// Scheduled dials (fallback waits and retries), by service name.
    private var waitTasks: [String: Task<Void, Never>] = [:]
    /// Services currently advertised, from the browser's latest results.
    private var advertised: [String: Bonjour.Endpoint] = [:]
    /// Consecutive failed attempts per service; reset when a link comes up.
    private var retryAttempts: [String: Int] = [:]
    private var listenerTask: Task<Void, Never>?
    private var browserTask: Task<Void, Never>?

    /// - Parameter includePeerToPeer: Enables AWDL so phones connect with no
    ///   shared Wi-Fi network. Tests on a Mac can turn it off.
    public init(localPeer: PeerID, includePeerToPeer: Bool = true) {
        self.localPeer = localPeer
        self.includePeerToPeer = includePeerToPeer
        serviceName = ServiceName.random()
        (events, continuation) = AsyncStream.makeStream(of: TransportEvent.self)
    }

    public func start() async throws {
        switch state {
        case .started: return
        case .stopped: throw TransportError.stopped
        case .idle: state = .started
        }

        let listener = try NetworkListener(
            for: .bonjour(name: serviceName, type: Self.serviceType),
            using: parameters()
        )
        listenerTask = Task { [weak self] in
            do {
                try await listener.run { [weak self] connection in
                    await self?.runLink(connection, direction: .incoming)
                }
            } catch {
                await self?.log("listener ended: \(error)")
            }
        }

        let browserParameters = NWParameters()
        browserParameters.includePeerToPeer = includePeerToPeer
        let browser = NetworkBrowser(for: .bonjour(Self.serviceType), using: browserParameters)
        browserTask = Task { [weak self] in
            do {
                try await browser.run { [weak self] endpoints in
                    await self?.discovered(endpoints)
                }
            } catch {
                await self?.log("browser ended: \(error)")
            }
        }
    }

    public func send(_ frame: Frame, to peer: PeerID) async throws {
        guard state == .started else { throw state == .idle ? TransportError.notStarted : TransportError.stopped }
        guard let link = links[peer] else { throw TransportError.peerUnreachable(peer) }
        do {
            try await link.connection.send(frame.bytes, type: LinkMessageType.frame.rawValue)
        } catch {
            throw TransportError.failed(String(describing: error))
        }
    }

    public func stop() async {
        guard state != .stopped else { return }
        state = .stopped
        listenerTask?.cancel()
        browserTask?.cancel()
        // Pending dials and waits must not outlive the transport: a dial in
        // its hello exchange would otherwise keep connecting after Stop.
        for task in dialTasks.values { task.cancel() }
        for task in waitTasks.values { task.cancel() }
        dialTasks.removeAll()
        waitTasks.removeAll()
        advertised.removeAll()
        let open = links
        links.removeAll()
        for (peer, link) in open {
            link.task.cancel()
            continuation.yield(.peerUnavailable(peer))
        }
        continuation.finish()
    }

    // MARK: - Discovery and redial

    private func discovered(_ endpoints: [Bonjour.Endpoint]) {
        guard state == .started else { return }
        advertised = Dictionary(
            endpoints.filter { $0.name != serviceName }.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Stop waiting on services that disappeared.
        for (name, task) in waitTasks where advertised[name] == nil {
            task.cancel()
            waitTasks[name] = nil
        }
        retryAttempts = retryAttempts.filter { advertised[$0.key] != nil }
        for name in advertised.keys.sorted() { connect(to: name, after: .zero) }
    }

    /// Connects to an advertised service unless already linked or trying.
    /// The side whose service name sorts higher dials after `delay`; the other
    /// waits at least `DialRule.fallbackDelay`, in case discovery was one-sided.
    private func connect(to name: String, after delay: Duration) {
        guard canConnect(to: name) else { return }
        let wait = DialRule.shouldDialImmediately(ownServiceName: serviceName, discovered: name)
            ? delay
            : max(delay, DialRule.fallbackDelay)
        guard wait > .zero else {
            dial(name)
            return
        }
        waitTasks[name] = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.waitFinished(name)
        }
    }

    private func canConnect(to name: String) -> Bool {
        state == .started && advertised[name] != nil && !isLinked(serviceName: name)
            && dialTasks[name] == nil && waitTasks[name] == nil
    }

    private func waitFinished(_ name: String) {
        waitTasks[name] = nil
        dial(name)
    }

    private func dial(_ name: String) {
        guard state == .started, let endpoint = advertised[name], dialTasks[name] == nil, !isLinked(serviceName: name) else { return }
        let connection = Connection(to: endpoint.nwEndpoint, using: parameters())
        dialTasks[name] = Task { [weak self] in
            await self?.runLink(connection, direction: .outgoing)
            await self?.finishedDialing(name)
        }
    }

    private func finishedDialing(_ name: String) {
        dialTasks[name] = nil
        // Covers both a dial that never linked and an outgoing link that
        // dropped (its `unregister` ran while this dial task still existed).
        retry(name)
    }

    /// Schedules a bounded, backed-off redial if the service is still
    /// advertised and nothing is linked or in flight. Only counts an attempt
    /// when it actually schedules one.
    private func retry(_ name: String) {
        guard canConnect(to: name) else { return }
        let attempt = retryAttempts[name, default: 0] + 1
        guard let delay = RetryPolicy.delay(forAttempt: attempt) else {
            log("giving up on \(name) after \(RetryPolicy.maxAttempts) attempts")
            return
        }
        retryAttempts[name] = attempt
        connect(to: name, after: delay)
    }

    private func isLinked(serviceName name: String) -> Bool {
        links.values.contains { $0.serviceName == name }
    }

    /// Simulates every link failing (without stopping), for tests of redial.
    package func dropLinksForTesting() {
        for link in links.values { link.task.cancel() }
    }

    /// Dials and fallback waits still pending. Zero after `stop()`.
    package var pendingTaskCount: Int { dialTasks.count + waitTasks.count }

    // MARK: - Links

    /// Runs one connection until it closes: hello exchange, registration,
    /// then the receive loop.
    private func runLink(_ connection: Connection, direction: LinkDirection) async {
        do {
            let hello = try await exchangeHello(on: connection)
            let remote = hello.peer
            guard remote != localPeer, !Task.isCancelled else { return }

            let id = UUID()
            // The receive loop runs in its own task so a duplicate link can be
            // dropped by cancelling it.
            let task = Task { [weak self] in
                guard let self else { return }
                await self.receiveLoop(connection, from: remote)
            }
            let link = Link(id: id, direction: direction, serviceName: hello.serviceName, connection: connection, task: task)
            guard register(link, for: remote) else {
                task.cancel()
                return
            }
            // The receive loop is its own task; cancelling this one (Stop,
            // or a cancelled dial) must reach it.
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            unregister(id: id, for: remote)
        } catch {
            log("link \(direction) failed: \(error)")
        }
    }

    /// Sends our hello and reads the peer's under one timeout. The send is
    /// inside it because a dial to a stale endpoint can wait indefinitely for
    /// the connection to open.
    private func exchangeHello(on connection: Connection) async throws -> LinkHello {
        let ours = try LinkHello(peer: localPeer, serviceName: serviceName).encoded
        return try await withThrowingTaskGroup(of: LinkHello.self) { group in
            group.addTask {
                try await connection.send(ours, type: LinkMessageType.hello.rawValue)
                let message = try await connection.receive()
                guard message.metadata.type == LinkMessageType.hello.rawValue else {
                    throw ValidationError("LocalP2P", "expected hello")
                }
                return try LinkHello(decoding: message.content)
            }
            group.addTask {
                try await Task.sleep(for: Self.helloTimeout)
                throw TransportError.failed("hello timed out")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func receiveLoop(_ connection: Connection, from remote: PeerID) async {
        while !Task.isCancelled {
            do {
                let message = try await connection.receive()
                guard message.metadata.type == LinkMessageType.frame.rawValue else {
                    log("unexpected message type \(message.metadata.type) from \(remote.short); closing")
                    return
                }
                deliver(try Frame(message.content), from: remote)
            } catch {
                return
            }
        }
    }

    private func deliver(_ frame: Frame, from remote: PeerID) {
        // Only the surviving link for this peer may deliver.
        guard state == .started, links[remote] != nil else { return }
        continuation.yield(.received(frame, from: remote))
    }

    /// Returns false if the new link loses to an existing one.
    private func register(_ link: Link, for remote: PeerID) -> Bool {
        guard state == .started else { return false }
        if let existing = links[remote] {
            guard LinkArbiter.shouldReplace(existing: existing.direction, with: link.direction, local: localPeer, remote: remote) else {
                return false
            }
            links[remote] = link
            existing.task.cancel()
            return true
        }
        links[remote] = link
        retryAttempts[link.serviceName] = nil
        continuation.yield(.peerAvailable(remote))
        return true
    }

    private func unregister(id: UUID, for remote: PeerID) {
        guard let link = links[remote], link.id == id else { return }
        links.removeValue(forKey: remote)
        guard state == .started else { return }
        continuation.yield(.peerUnavailable(remote))
        // An incoming link has no dial task to retry for it; do it here. For
        // an outgoing link this is a no-op and `finishedDialing` retries.
        retry(link.serviceName)
    }

    private func parameters() -> NWParametersBuilder<TLV> {
        .parameters {
            TLV(type: UInt8.self, length: UInt16.self) { TCP() }
        }
        .peerToPeerIncluded(includePeerToPeer)
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[LocalP2P \(localPeer.short)] \(message)")
        #endif
    }
}
