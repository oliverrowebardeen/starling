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
    private var dialing: Set<String> = []
    private var pendingFallbacks: Set<String> = []
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
        let open = links
        links.removeAll()
        for (peer, link) in open {
            link.task.cancel()
            continuation.yield(.peerUnavailable(peer))
        }
        continuation.finish()
    }

    // MARK: - Discovery

    private func discovered(_ endpoints: [Bonjour.Endpoint]) {
        guard state == .started else { return }
        for endpoint in endpoints where endpoint.name != serviceName {
            if DialRule.shouldDialImmediately(ownServiceName: serviceName, discovered: endpoint.name) {
                dial(endpoint)
            } else if !isLinked(serviceName: endpoint.name), pendingFallbacks.insert(endpoint.name).inserted {
                // The other side should dial us. Dial anyway if it has not
                // after a short wait, in case it cannot see our service.
                Task { [weak self] in
                    try? await Task.sleep(for: DialRule.fallbackDelay)
                    await self?.fallbackDial(endpoint)
                }
            }
        }
    }

    private func dial(_ endpoint: Bonjour.Endpoint) {
        let name = endpoint.name
        guard state == .started, !dialing.contains(name), !isLinked(serviceName: name) else { return }
        dialing.insert(name)
        let connection = Connection(to: endpoint.nwEndpoint, using: parameters())
        Task { [weak self] in
            await self?.runLink(connection, direction: .outgoing)
            await self?.finishedDialing(name)
        }
    }

    private func fallbackDial(_ endpoint: Bonjour.Endpoint) {
        pendingFallbacks.remove(endpoint.name)
        dial(endpoint)
    }

    private func isLinked(serviceName name: String) -> Bool {
        links.values.contains { $0.serviceName == name }
    }

    private func finishedDialing(_ name: String) {
        // Allow a redial if the service is still advertised later.
        dialing.remove(name)
    }

    // MARK: - Links

    /// Runs one connection until it closes: hello exchange, registration,
    /// then the receive loop.
    private func runLink(_ connection: Connection, direction: LinkDirection) async {
        do {
            try await connection.send(LinkHello(peer: localPeer, serviceName: serviceName).encoded, type: LinkMessageType.hello.rawValue)
            let hello = try await receiveHello(on: connection)
            let remote = hello.peer
            guard remote != localPeer else { return }

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
            await task.value
            unregister(id: id, for: remote)
        } catch {
            log("link \(direction) failed: \(error)")
        }
    }

    private func receiveHello(on connection: Connection) async throws -> LinkHello {
        try await withThrowingTaskGroup(of: LinkHello.self) { group in
            group.addTask {
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
        continuation.yield(.peerAvailable(remote))
        return true
    }

    private func unregister(id: UUID, for remote: PeerID) {
        guard links[remote]?.id == id else { return }
        links.removeValue(forKey: remote)
        if state == .started { continuation.yield(.peerUnavailable(remote)) }
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
