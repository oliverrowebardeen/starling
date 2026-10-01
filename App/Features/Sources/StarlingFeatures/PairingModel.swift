import Foundation
import Observation
import StarlingCore

/// A nearby phone the owner can pair with: reachable on a link, not pinned.
public struct PairingCandidate: Identifiable, Hashable, Sendable {
    public var id: PeerID { peer }
    public let peer: PeerID
    /// Which link it was seen on, for the owner ("Wi-Fi Aware", "Nearby").
    public let link: String

    public init(peer: PeerID, link: String) {
        self.peer = peer
        self.link = link
    }
}

/// What the pairing screen needs from the app's links (lane E1's
/// PairingService and SecureTransports, docs/requests/E1.md item 2).
public struct PairingDirectory: Sendable {
    /// This phone's PeerID, so both owners can tell the phones apart.
    public var localPeer: PeerID
    /// Nearby phones that are not paired yet.
    public var candidates: @Sendable () async -> [PairingCandidate]
    /// Starts a ceremony with `candidate`, saving it as `nickname` if both
    /// owners confirm. Lane E1 commits the pin; the app never writes it.
    public var pair: @Sendable (PairingCandidate, String) async throws -> any PairingSession
    /// Called once paired, to reconnect each link to the new friend.
    public var paired: @Sendable (PairedPeer) async -> Void
    /// The PeerID behind a device the owner picked in the system's Wi-Fi
    /// Aware picker (lane E2's `peerID(for:waitingUpTo:)`), or nil if its
    /// link hello did not arrive in time. Nil where Wi-Fi Aware is absent.
    public var peerForPickedDevice: (@Sendable (UInt64) async -> PeerID?)?

    public init(
        localPeer: PeerID,
        candidates: @escaping @Sendable () async -> [PairingCandidate],
        pair: @escaping @Sendable (PairingCandidate, String) async throws -> any PairingSession,
        paired: @escaping @Sendable (PairedPeer) async -> Void,
        peerForPickedDevice: (@Sendable (UInt64) async -> PeerID?)? = nil
    ) {
        self.peerForPickedDevice = peerForPickedDevice
        self.localPeer = localPeer
        self.candidates = candidates
        self.pair = pair
        self.paired = paired
    }
}

/// Drives the in-person pairing ceremony (ADR 0003, lane E1): pick the
/// nearby phone, name the friend, then both people compare a code and
/// confirm or cancel. The friend is saved by lane E1 only if both confirm.
@MainActor
@Observable
public final class PairingModel {
    public enum Phase: Hashable, Sendable {
        /// Choosing the phone and the name.
        case idle
        case starting
        /// Both phones show this code. Pairing continues only if both match.
        case comparing(code: String)
        /// This owner confirmed; waiting for the other phone.
        case confirming
        case paired(PairedPeer)
        case failed(PairingFailure)
    }

    public private(set) var phase = Phase.idle
    public private(set) var candidates: [PairingCandidate] = []
    public var selected: PairingCandidate?
    public var nickname = ""
    public private(set) var notice: String?
    public var localPeer: PeerID { directory.localPeer }

    private let directory: PairingDirectory
    private var session: (any PairingSession)?
    private var events: Task<Void, Never>?
    /// Set when the pairing screen went away, so a session that is still
    /// being created is cancelled as soon as it exists.
    private var isEnded = false

    public init(directory: PairingDirectory) {
        self.directory = directory
    }

    public func refreshCandidates() async {
        var fresh = await directory.candidates()
        // A phone picked in the system picker stays listed even before the
        // link watcher reports it.
        if let selected, !fresh.contains(selected) { fresh.insert(selected, at: 0) }
        candidates = fresh
    }

    /// The owner picked a device in the system's Wi-Fi Aware picker: select
    /// the PeerID behind it, and suggest the device's name if the owner has
    /// not typed one. The code comparison still verifies the pick (ADR 0003).
    public func pickedDevice(id: UInt64, name: String) async {
        guard let resolve = directory.peerForPickedDevice else { return }
        notice = nil
        guard let peer = await resolve(id) else {
            notice = "Starling couldn't reach the phone you picked. Keep both phones close and open Starling on both, then try again."
            return
        }
        let candidate = candidates.first { $0.peer == peer } ?? PairingCandidate(peer: peer, link: "Wi-Fi Aware")
        if !candidates.contains(candidate) { candidates.insert(candidate, at: 0) }
        selected = candidate
        if nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { nickname = name }
    }

    /// A phone is chosen and the nickname is one lane E1 will accept.
    public var canStart: Bool {
        guard selected != nil else { return false }
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...PairedPeer.maxNicknameCharacters).contains(trimmed.count)
    }

    public func start() async {
        switch phase {
        case .idle, .paired, .failed: break
        default: return
        }
        guard canStart, let selected else {
            notice = "Pick a phone and name your friend (1 to \(PairedPeer.maxNicknameCharacters) characters)."
            return
        }
        phase = .starting
        notice = nil
        do {
            let session = try await directory.pair(selected, nickname.trimmingCharacters(in: .whitespacesAndNewlines))
            if isEnded {
                await session.cancel()
                phase = .failed(.cancelled)
                return
            }
            self.session = session
            events = Task { [weak self] in
                for await event in session.events {
                    await self?.handle(event)
                }
                self?.streamEnded()
            }
        } catch {
            phase = .failed(.transportFailed)
        }
    }

    /// The owner compared the codes on both phones.
    public func confirm(codesMatch: Bool) async {
        guard case .comparing = phase, let session else { return }
        phase = .confirming
        await session.confirm(codesMatch: codesMatch)
    }

    public func cancel() async {
        guard let session else {
            phase = .idle
            return
        }
        await session.cancel()
    }

    /// The pairing screen went away, for example swiped down. Cancels a
    /// ceremony in progress so it does not keep running with no screen;
    /// a finished pairing is left alone.
    public func end() async {
        isEnded = true
        switch phase {
        case .starting, .comparing, .confirming:
            await session?.cancel()
        case .idle, .paired, .failed:
            break
        }
    }

    public func reset() {
        isEnded = false
        events?.cancel()
        events = nil
        session = nil
        notice = nil
        phase = .idle
    }

    func handle(_ event: PairingEvent) async {
        switch event {
        case .confirmCode(let code):
            phase = .comparing(code: code)
        case .paired(let peer):
            await directory.paired(peer)
            phase = .paired(peer)
        case .failed(let failure):
            phase = .failed(failure)
        }
    }

    private func streamEnded() {
        session = nil
        events = nil
        switch phase {
        case .starting, .comparing, .confirming:
            // The session ended without a result.
            phase = .failed(.protocolError)
        default:
            break
        }
    }

    /// What to tell the owner about a failure.
    public static func message(for failure: PairingFailure) -> String {
        switch failure {
        case .codeMismatch:
            "The codes didn't match, so Starling didn't pair. If you picked the right phone, someone nearby may be interfering. Try again somewhere else."
        case .cancelled:
            "Pairing was cancelled."
        case .timedOut:
            "Pairing took too long. Keep both phones close and try again."
        case .transportFailed:
            "Starling couldn't reach the other phone. Keep both phones close and try again."
        case .protocolError:
            "The other phone answered in a way Starling didn't expect. Make sure both phones have the latest Starling and try again."
        }
    }
}
